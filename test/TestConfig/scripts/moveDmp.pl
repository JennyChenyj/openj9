##############################################################################
#  Licensed Materials - Property of IBM
#  Copyright (c) 2006, 2019 IBM Corp. All Rights Reserved.
#  US Government Users Restricted Rights - Use, duplication or
#  disclosure restricted by GSA ADP Schedule Contract with IBM Corp.
##############################################################################

use strict;
use File::Spec::Functions;
use Time::Local;
use feature qw(switch);

our $TRUE = 1;
our $FALSE = 0;
our $SUCCESS = 1;
our $FAILURE = 0;

sub logMsg {
	my ($second,$minute,$hour,$day,$month,$year,undef,undef,undef) = localtime;
	$month++;
	$year+=1900;
	printf("%04d%02d%02d-%02d:%02d:%02d - ",$year,$month,$day,$hour,$minute,$second);
	my $val = shift;
	# Wipe any trailing \n's
	$val=~ s/\r|\n//g;
	print $val."\n";
}

sub strip {
	my ($str) = @_;
	$str =~ s/^\s+//g;
	$str =~ s/\s+$//g;
	return $str;
}

sub storeFile {
	# get filename and search argument
	my ($filename) = @_;
	my @lines = ();
	# strip out any quotes...
	($filename) =~ s/\"//g;
	# check the file exists
	if (!(-e $filename)) {
		logMsg("SYSTEM ERROR: The system cannot find the file $filename.");
		return [];
	}
	if (!(-r $filename)) {
		logMsg("SYSTEM ERROR: The system does not have read access to the file $filename.");
		return [];
	}
	# open file
	open (FILE, "<$filename");
	# search array
	@lines = <FILE>;
	close FILE;
	return \@lines;
}

sub runTimedCmd {
	my (%args) = @_;              # The args
	my $command = "";                    # The command to run
	my $log = "";                        # The file to log the output to
	my $time = 0;                        # The time to run the command for
	my $rc = 1;
	my $echo = $FALSE;                   # If set to true the output is echoed to the screen
	my $oldlen = 0;                      # The length of the log file before new messages are added
	if (exists $args{cmd}) {
		$command = $args{cmd};
	}
	if ($command eq "") {
		logMsg("ERROR: Unable to run command as no command was specified (runCmd(cmd => command))");
		return wantarray ? ($FAILURE, undef) : $FAILURE;
	}
	if (exists $args{log}) {
		$log = $args{log};
	}
	if (exists $args{period}) {
		$time = $args{period};
	}
	if (exists $args{echo}) {
		$echo = $args{echo};
		if ($echo == $TRUE) {
			open (OLDLOG, "<$log");
			my @oldlog = (<OLDLOG>);
			$oldlen = @oldlog;
			close (OLDLOG);
		}
	}
	# Split the command into cmd and arguments
	my @cmd_elements = split(" ", $command);
	my $cmd = shift @cmd_elements;
	my @args = @cmd_elements;
	qx($cmd @args 2>$log);
	$rc = $?;
	if ($echo == $TRUE) {
		# open the output file
		open NEWLOG, "<$log";
		# move to the end of the old log in the new log ...
		my $cnt = 0;
	FINDPOS: while(<NEWLOG>) {
		$cnt = $cnt + 1;
		if ($cnt == $oldlen) {
			last FINDPOS;
		}
	}
	}
	if ($echo == $TRUE) {
		foreach my $line (<NEWLOG>) {
			print STDOUT "$line";
		}
		# Close the output file
		close NEWLOG;
	}
	return wantarray ? ( $SUCCESS, $rc ) : $rc;
}

sub moveTDUMPS {
	my ($file, $moveLocation) = @_;
	logMsg("Moving the TDUMPS to '$moveLocation', using log to identify the TDUMP name to be moved");
	if ($^O ne 'os390') {
		return;
	}
	my @dumplist = ();
	# Use a hash to ensure that each dump is only dealt with once
	my %parsedNames = ();
	if ($file) {
		if ($file =~ /IEATDUMP success for DSN='.*'/) {
			my ($tdump) = $file =~ /IEATDUMP success for DSN='(.*)'/;
			$parsedNames{$tdump} = 1;
		}
	    # A partial dump has been created, even though it is a failure, dump still occurred and needs moving
		if ($file =~ /IEATDUMP failure for DSN='.*' RC=0x00000004 RSN=0x00000000/) {
			my ($tdump) = $file =~ /IEATDUMP failure for DSN='(.*)'/;
			$parsedNames{$tdump} = 1;
		}
		# Dump failed due to no space left on the machine, so print out warning message
		if ($file =~ /IEATDUMP failure for DSN='.*' RC=0x00000008 RSN=0x00000026/) {
			logMsg("ERROR: TDUMP failed due to no space left on machine");
			my ($tdump) = $file =~ /IEATDUMP failure for DSN='(.*)'/;
			$parsedNames{$tdump} = 1;
		}
	}
	push(@dumplist, keys(%parsedNames));
	if (!@dumplist) {
		logMsg("No dumps names found in logs/supplied");
		# Nothing to do
		return;
	}
	logMsg("Attempting to retrieve dumps with names: '" . join("', '", @dumplist), "'");
	my %movedDumps = ();
	my $multipartIndex = 0;
	foreach my $dump (@dumplist) {
		if ($dump =~ /X&DS/) {
			logMsg("Naming of dump consistent with multiple dumps \n");
		}
		if ($dump !~ /X&DS/) {
			# Remove the leading username JENKINS from the title of dump to match the required format for moving files
			my $dumpName = substr $dump, 8;
			my $cmd = "mv //${dumpName} ". catfile($moveLocation, "core."."$dump".".dmp");
			my ($status, $exitstatus) = runTimedCmd(cmd    => $cmd,
			period => 300,
			log    => "move.log");
			if (-e "move.log") {
				my $movelog = storeFile("move.log");
				if (scalar (@{$movelog}) == 0) {
					logMsg("Found TDUMP named $dump, moved to $moveLocation");
					$movedDumps{$dump} = 1;
				} else {
					logMsg("Contents of TDUMP move log:");
					foreach my $line (@{$movelog}){
						($line) = strip($line);
						print ("$line \n");
						if ($line =~ /(invalid|not found)/) {
							logMsg("Unable to find TDUMP named $dump");
						} elsif ($line =~ /(write error|no space left)/) {
							logMsg("ERROR: Machine disk full, unable to move dump, aborting move..");
							my $cmd = "mv //${dumpName} /dev/null";
							my ($status, $exitstatus) = (cmd    => $cmd,
							period => 300,
							log    => "delete.log");
							logMsg("ERROR: Machine disk full, unable to move dump, moving to dev null instead, so should be deleted..");
							if (-e "delete.log") {
								my $deletelog = storeFile("delete.log");
								if (scalar (@{$deletelog}) == 0) {
									logMsg("Successfully deleted dump");
								} else {
									logMsg("Unable to delete dump");
									foreach my $line (@{$deletelog}) {
										($line) = strip($line);
										logmsg("$line \n");
									}
								}
							}
						} else {
							logMsg("Found TDUMP named $dump, moved to $moveLocation");
							$movedDumps{$dump} = 1;
						}
					}
					logMsg("End of move log \n");
					unlink($movelog);
				}
			} else {
				logMsg("CAUTION: The attempted move of dump $dump to ".catfile($moveLocation, "core.".$dump.".dmp")." did not produce a log file, nothing probably happened!");
				logMsg("       : Please check manually that this file is no longer on the filesystem - otherwise it may take up space needlessly");
			}
		} else {
			my @parts;
			$dump =~ s/\.X&DS//;
			logMsg("Changed dump name to $dump \n");
			my $num = qx(tso listcat | grep $dump | wc -l);
			$num =~ s/^\s+|\s+$//g;
			my $numFiles = int($num);
			my $dump01;
			for (my $i=1; $i <= $numFiles; $i++) {
				given ($i) {
					when ($i < 10) {
						$dump01 = $dump.".X00".$i;
					}
					when ($i < 100) { 
						$dump01 = $dump.".X0".$i;
					}
					when ($i < 1000) {
						$dump01 = $dump.".X".$i;
					}
				}
				# Remove the leading username JENKINS from the title of dump to match the required format for concatenating files
				my $dumpName = substr $dump01, 8;
				logMsg("Looking for multiple TDUMPs $dump \n");
				logMsg("Adding the contents of ${dumpName} to core.$dump.dmp \n");
				my $cmd = "cat //${dumpName} ".">> ". catfile($moveLocation, "core."."$dump".".dmp");
				my ($status, $exitstatus) = runTimedCmd(cmd    => $cmd,
				period => 300,
				log    => "move.log");
				my $movelog = storeFile("move.log");
				if(scalar (@{$movelog}) != 0) {
					logMsg("Contents of TDUMP multiple move log:");
					# The command failed if there is anything in the move error log
					foreach my $line (@{$movelog}) {
						($line) = strip($line);
						print ("$line \n");
						if ($line =~ /(invalid|cannot open file|could not be located)/) {
							logMsg("Unable to find multiple TDUMP named $dump01, assuming there are no more parts of the TDUMP to move");
						} elsif ($line =~ /(No such file or directory)/) {
							logMsg("ERROR: unable to find the directory to place the dump");
						}
					}
				}
				my $cmd = "mv //${dumpName} /dev/null";
				my ($status, $exitstatus) = runTimedCmd(cmd    => $cmd,
				period => 300,
				log    => "delete.log");
				if (-e "delete.log") {
					my $deletelog = storeFile("delete.log");
					if (scalar (@{$deletelog}) == 0) {
						logMsg("Successfully deleted dump");
					} else {
 						logMsg("Unable to delete dump");
						foreach my $line (@{$deletelog}) {
							($line) = strip($line);
							logMsg("$line \n");
						}
					}
				}
				$movedDumps{$dump01} = 1;
			}
		}
	}
	my @returnList = keys(%movedDumps);
	logMsg("TDUMP Summary:");
	foreach my $line (@returnList) {
		print("$line \n");
	}
	logMsg("End of TDUMP Summary");
	return (@returnList);
}

1;
