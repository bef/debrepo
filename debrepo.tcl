#!/usr/bin/env tclsh
##
## simple debian repository creator (for binary packages)
##
## (c) 2014, Ben Fuhrmannek - <bef@pentaphase.de>
##

package require Tcl 8.5
package require inifile
package require fileutil
package require md5
package require sha1
package require sha256

## functions

proc log {msg} { puts "\[*\] $msg" }

proc parseini {fn} {
	set repos {}
	set ini [::ini::open $fn r]
	foreach sec [::ini::sections $ini] {
		if {$sec eq "GLOBAL"} { set ::cfg [::ini::get $ini $sec]; continue }
		dict set repos $sec [::ini::get $ini $sec]
	}
	::ini::close $ini
	return $repos
}

proc parsectl {data} {
	set key ""
	set res {}
	foreach line [split $data "\n"] {
		if {[regexp -- {^ } $line]} {
			dict append res $key "\n$line"
		} elseif {[regexp -- {^(.*?): (.*)$} $line -> key value]} {
			dict set res $key $value
		}
	}
	return $res
}

proc dumpctl {ctl} {
	set res ""
	foreach {k v} $ctl {
		append res "$k: $v\n"
	}
	return $res
}

proc dumpPackage {ctl} {
	## reorder dict to have 'Package:' first
	set name [dict get $ctl Package]
	set ctl [dict remove $ctl Package]
	set ctl [linsert $ctl 0 Package $name]
	
	return [dumpctl $ctl]
}

## returns -1, 0, 1 for < = >
proc cmp_deb_version {v1 v2} {
	if {$v1 eq $v2} { return 0 }

	## compare epoch
	set epoch1 ""
	set epoch2 ""
	regexp -- {^(\d+):(.*)$} $v1 -> epoch1 v1
	regexp -- {^(\d+):(.*)$} $v2 -> epoch2 v2
	if {$epoch1 ne "" && $epoch2 ne ""} {
		if {$epoch1 < $epoch2} { return -1 }
		if {$epoch1 > $epoch2} { return 1 }
	}

	## compare upstream version
	set deb1 ""
	set deb2 ""
	if {![regexp -- {^(.*?)-(.*)$} $v1 -> upstream1 deb1]} { set upstream1 $v1 }
	if {![regexp -- {^(.*?)-(.*)$} $v2 -> upstream2 deb2]} { set upstream2 $v2 }
	foreach a [split $upstream1 "."] b [split $upstream2 "."] {
		if {$a eq $b} { continue }
		if {[string is integer $a] && [string is integer $b]} {
			if {$a < $b} { return -1 }
			if {$a > $b} { return 1 }
		}
	}
	
	## compare debian revision
	set extra1 ""
	set extra2 ""
	regexp -- {^(\d+)~(.*)$} $v1 -> deb1 extra1
	regexp -- {^(\d+)~(.*)$} $v2 -> deb2 extra1
	if {![string is integer $deb1] || ![string is integer $deb2]} { return [string compare $deb1 $deb2] }
	if {$deb1 < $deb2} { return -1 }
	if {$deb1 > $deb2} { return 1 }
	
	## finally compare debian revision extra (after ~)
	return [string compare $extra1 $extra2]
}

## globals

set cfg {}
set repos [parseini debrepo.ini]

##
set signfiles {}
foreach {dist repo} $repos {
	set sumfiles {}
	foreach comp [dict get $repo Components] {
		set pooldir "pool/$dist/$comp"
		log "pool: $pooldir"

		## init packages dict -> {$arch {{pkg1} {pkg2} ...}}
		set packages {}
		foreach arch [dict get $repo Architectures] {
			dict set packages $arch {}
		}

		## find all packages for pool
		set fnversion {}
		set files {}
		foreach fn [glob -nocomplain -directory $pooldir *.deb] {
			if {![regexp -- {.*/(.*?)_(.*?)_(.*)\.deb$} $fn -> fn_name fn_version fn_arch]} {
				log "  :( invalid package name. ignoring $fn"
				continue
			}
			set key [list $fn_name $fn_arch]
			if {[dict exists $fnversion $key]} {
				set version [dict get $fnversion $key]
				if {[cmp_deb_version $version $fn_version] >= 0} { continue}
			}
			dict set fnversion $key $fn_version
			dict set files $key $fn
		}
		foreach fn [dict values $files] {
			log " -> processing $fn"
			set ctlraw [exec -- dpkg-deb -f $fn]
			set ctl [parsectl $ctlraw]
			if {![dict exists $ctl Architecture]} {
				puts ":( Architecture not set. moving on."
				continue
			}
			set arch [dict get $ctl Architecture]
			if {![dict exists $packages $arch]} {
				puts ":( Architecture '$arch' not configured. ignoring package."
				continue
			}
			
			## add mandatory fields to package ctl
			dict set ctl Filename $fn
			dict set ctl Size [file size $fn]
			dict set ctl MD5sum [string tolower [::md5::md5 -hex -file $fn]]
			dict set ctl SHA1 [::sha1::sha1 -hex -file $fn]
			dict set ctl SHA256 [::sha2::sha256 -hex -file $fn]
			
			## add to list of packages by arch
			dict lappend packages $arch [dumpPackage $ctl]
		}

		foreach arch [dict get $repo Architectures] {
			set archdir "dists/$dist/$comp/binary-$arch"
			log "archdir: $archdir"
			file mkdir $archdir
			
			log " + creating Packages file"
			set data [join [dict get $packages $arch] "\n"]
			append data "\n"
			::fileutil::writeFile "$archdir/Packages" $data
			exec gzip -9kf "$archdir/Packages"
			exec bzip2 -9kf "$archdir/Packages"
			lappend sumfiles "$archdir/Packages" "$archdir/Packages.gz" "$archdir/Packages.bz2"

			log " + creating Release file"
			set release {}
			foreach {k v} $repo {
				if {[lsearch -exact {Description Origin Label Version Suite Codename} $k] >= 0} {
					dict set release $k $v
				}
			}
			dict set release Component $comp
			dict set release Architecture $arch
			set data [dumpctl $release]
			::fileutil::writeFile "$archdir/Release" $data
			lappend sumfiles "$archdir/Release"
		}
	}
	
	log "creating Release file for $dist"
	set release {}
	foreach {k v} $repo {
		if {[lsearch -exact {Description Origin Label Version Suite Codename Architectures Components} $k] >= 0} {
			dict set release $k $v
		}
	}
	foreach {key hashfunc} {MD5Sum ::md5::md5 SHA1 ::sha1::sha1 SHA256 ::sha2::sha256} {
		dict set release $key ""
		foreach sumfile $sumfiles {
			set sum [string tolower [$hashfunc -hex -file $sumfile]]
			set size [file size $sumfile]
			set fn [file join {*}[lrange [file split $sumfile] 2 end]]
			dict append release $key "\n $sum $size $fn"
		}
	}

	::fileutil::writeFile "dists/$dist/Release" [dumpctl $release]
	lappend signfiles "dists/$dist/Release"
}

if {[dict exists $cfg signkey]} {
	log "signing Release files"
	foreach fn $signfiles {
		if {[file exists "${fn}.gpg"]} { file delete "${fn}.gpg" }
		exec gpg2 --local-user [dict get $cfg signkey] --armor --detach-sign -o "${fn}.gpg" --sign "$fn" 
	}
} else {
	log "signkey not set. not signing Release files."
}

