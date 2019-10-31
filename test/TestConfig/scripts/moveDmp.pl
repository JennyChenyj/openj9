#Licensed Materials - Property of IBM
#common::ras.pm
#(C) Copyright IBM Corp. 2006, 2019. All Rights Reserved.
#US Government Users Restricted Rights - Use, duplication or
#disclosure restricted by GSA ADP Schedule Contract with IBM Corp.



use strict;
use Carp qw(cluck);
use File::Spec::Functions;
use Time::Local;

our $TRUE = 1;
our $FALSE = 0;
our $SUCCESS = 1;
our $FAILURE = 0;

sub logMsg
{
    my ($second,$minute,$hour,$day,$month,$year,undef,undef,undef) = localtime;
    $month++;
    $year+=1900;
    
    printf("%04d%02d%02d-%02d:%02d:%02d - ",$year,$month,$day,$hour,$minute,$second);
    
    my $val = shift;
    $val=~ s/\r|\n//g; #Wipe any trailing \n's
    print $val."\n";
}

sub strip
{
    
    my ($str) = @_;
    
    $str =~ s/^\s+//g;
    $str =~ s/\s+$//g;
    
    return $str;
}


sub storeFile
{
    # get filename and search argument
    my ($filename) = @_;
    my @lines = ();
    
    # strip out any quotes...
    ($filename) =~ s/\"//g;
    
    # check the file exists
    if (!(-e $filename))
    {
        logMsg("SYSTEM ERROR: The system cannot find the file $filename.");
        return [];
    }
    
    if (!(-r $filename))
    {
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

sub runTimedCmd
{
    my (%args) = @_;              # The args
    my $command = "";                    # The command to run
    my $log = "";                        # The file to log the output to
    my $time = 0;                        # The time to run the command for
    my $rc = 1;
    my $echo = $FALSE;                   # If set to true the output is echoed to the screen
    my $oldlen = 0;                      # The length of the log file before new messages are added
    
    if (exists $args{cmd})
    {
        $command = $args{cmd};
    }
    
    if ($command eq "")
    {
        logMsg("ERROR: Unable to run command as no command was specified (runCmd(cmd => command))");
        return wantarray ? ($FAILURE, undef) : $FAILURE;
    }
    
    if (exists $args{log})
    {
        $log = $args{log};
    }
    
    if (exists $args{period})
    {
        $time = $args{period};
    }
    
    if (exists $args{echo})
    {
        $echo = $args{echo};
        if ($echo == $TRUE)
        {
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
    qx($cmd @args >$log 2>&1);
    $rc = $?;
    
    if ($echo == $TRUE)
    {
        # open the output file
        open NEWLOG, "<$log";
        
        # move to the end of the old log in the new log ...
        my $cnt = 0;
    FINDPOS: while(<NEWLOG>)
    {
        $cnt = $cnt + 1;
        if ($cnt == $oldlen)
        {
            last FINDPOS;
        }
    }
    }
    
    if ($echo == $TRUE)
    {
        foreach my $line (<NEWLOG>) {
            print STDOUT "$line";
        }
        
        # Close the output file
        close NEWLOG;
    }
    
    
    return wantarray ? ( $SUCCESS, $rc ) : $rc;
}

sub moveTDUMPS
{
    my ($file, $moveLocation, $joinDumps) = @_;
    
    logMsg("Moving the TDUMPS to '$moveLocation', using log to identify the TDUMP name to be moved");
    
    if ($^O ne 'os390')
    {
        return;
    }
    my @dumplist = ();
    # Use a hash to ensure that each dump is only dealt with once
    my %parsedNames = ();
    if ($file)
    {
        if ($file =~ /IEATDUMP success for DSN='.*'/)
        {
            my ($tdump) = $file =~ /IEATDUMP success for DSN='(.*)'/;
            $parsedNames{$tdump} = 1;
        }
        if ($file =~ /IEATDUMP failure for DSN='.*' RC=0x00000004 RSN=0x00000000/)#A partial dump has been created, even though it is a failure, dump still occurred and needs moving
        {
            my ($tdump) = $file =~ /IEATDUMP failure for DSN='(.*)'/;
            $parsedNames{$tdump} = 1;
        }
        if ($file =~ /IEATDUMP failure for DSN='.*' RC=0x00000008 RSN=0x00000026/)#Dump failed due to no space left on the machine, so print out warning message
        {
            logMsg("ERROR: TDUMP failed due to no space left on machine");
            my ($tdump) = $file =~ /IEATDUMP failure for DSN='(.*)'/;
            $parsedNames{$tdump} = 1;
        }
    }
    push(@dumplist, keys(%parsedNames));
    
    if (!@dumplist)
    {
        logMsg("No dumps names found in logs/supplied");
        return; # Nothing to do;
    }
    
    logMsg("Attempting to retrieve dumps with names: '" . join("', '", @dumplist), "'");
    
    my %movedDumps = ();
    my $multipartIndex = 0;
    foreach my $dump (@dumplist)
    {
        
        if($dump =~ /X&DS/)
        {
            logMsg("Naming of dump consistent with multiple dumps \n");
        }
        
        if($dump !~ /X&DS/)
        {
            my $dumpName = substr $dump, 8;
            my $cmd = "mv //${dumpName} ". catfile($moveLocation, "$dump");            
            my ($status, $exitstatus) = runTimedCmd(cmd    => $cmd,
            period => 300,
            log    => "move.log");
            
            if (-e "move.log")
            {
                my $movelog = storeFile("move.log");
                if(scalar (@{$movelog}) == 0)
                {
                    logMsg("Found TDUMP named $dump, moved to $moveLocation");
                    $movedDumps{$dump} = 1;
                }
                else
                {
                    logMsg("Contents of TDUMP move log:");
                    foreach my $line (@{$movelog}){
                        ($line) = strip($line);
                        print ("$line \n");
                        if($line =~ /(invalid|not found)/)
                        {
                            logMsg("Unable to find TDUMP named $dump");
                        }
                        elsif($line =~ /(write error|no space left)/)
                        {
                            logMsg("ERROR: Machine disk full, unable to move dump, aborting move..");
                            my $cmd = "mv //${dumpName} /dev/null";
                            my ($status, $exitstatus) = (cmd    => $cmd,
                            period => 300,
                            log    => "delete.log");
                            logMsg("ERROR: Machine disk full, unable to move dump, moving to dev null instead, so should be deleted..");
                            if (-e "delete.log")
                            {
                                my $deletelog = storeFile("delete.log");
                                if(scalar (@{$deletelog}) == 0)
                                {
                                    logMsg("Successfully deleted dump");
                                }
                                else
                                {
                                    logMsg("Unable to delete dump");
                                    foreach my $line (@{$deletelog})
                                    {
                                        ($line) = strip($line);
                                        logmsg("$line \n");
                                    }
                                }
                            }
                        }
                        else
                        {
                            logMsg("Found TDUMP named $dump, moved to $moveLocation");
                            $movedDumps{$dump} = 1;
                        }
                    }
                    logMsg("End of move log \n");
                    unlink($movelog);
                }
            }
            else
            {
                logMsg("CAUTION: The attempted move of dump $dump to ".catfile($moveLocation, "$dump")." did not produce a log file, nothing probably happened!");
                logMsg("       : Please check manually that this file is no longer on the filesystem - otherwise it may take up space needlessly");
            }
        }
        else
        {
            my @parts;
            my $i = 1;
            my $multiFound = $TRUE;
            $dump =~ s/\.X&DS//;
            logMsg("Changed dump name to $dump \n");
            
            logMsg("Will scan for the dump, we expect a not-found failure at the end of this\n");
            
            while($multiFound == $TRUE && $i < 10)
            {
                my $dump01 = $dump.".X00".$i;
                my $dumpName = substr $dump01, 8;
                logMsg("Looking for multiple TDUMPs $dump \n");
                my $cmd = "mv //${dumpName} ". catfile($moveLocation, "$dump");
                my ($status, $exitstatus) = runTimedCmd(cmd    => $cmd,
                period => 300,
                log    => "move.log");
                my $movelog = storeFile("move.log");
                if(scalar (@{$movelog}) != 0)
                {   
                    logMsg("Contents of TDUMP multiple move log:");
                    
                    # GPV 18May2012. If there is ANYTHING in this I will now assume it failed
                    # Special case being if it failed because it was not found (various msgs) then thats an OK type fail
                    foreach my $line (@{$movelog})
                    {
                        ($line) = strip($line);
                        print ("$line \n");
                        
                        if($line =~ /(invalid|cannot open file|could not be located)/)
                        {
                            logMsg("Unable to find multiple TDUMP named $dump01, assuming there are no more parts of the TDUMP to move");
                            $multiFound = $FALSE;
                        }
                        elsif($line =~ /(write error|no space left)/)
                        {
                            logMsg("ERROR: Machine disk full, unable to move dump, aborting move..");
                            $multiFound = $FALSE;
                            
                            logMsg("ERROR: Machine disk full, unable to move dump, moving to dev null instead, so should be deleted..");
                            my $cmd = "mv //${dumpName} /dev/null";
                            my ($status, $exitstatus) = runTimedCmd(cmd    => $cmd,
                            period => 300,
                            log    => "delete.log");
                            if (-e "delete.log")
                            {
                                my $deletelog = storeFile("delete.log");
                                if(scalar (@{$deletelog}) == 0)
                                {
                                    logMsg("Successfully deleted dump");
                                }
                                else
                                {
                                    logMsg("Unable to delete dump");
                                    foreach my $line (@{$deletelog})
                                    {
                                        ($line) = strip($line);
                                        logMsg("$line \n");
                                    }
                                }
                            }
                        }
                    }
                    logMsg("Not withstanding previous msgs, the movelog was not NULL so will assume the move failed");
                    $multiFound = $FALSE;
                }
                
                # We will set multiFound to false if there is an error.
                if ($multiFound == $TRUE)
                {
                    logMsg("Found multiple TDUMP named $dump01, moved to $moveLocation");
                    push(@parts, $dump01);
                    if($i < 2)
                    {
                        logMsg("Added $dump01 to dump array");
                        $movedDumps{$dump01} = 1;
                    }
                    else
                    {
                        logMsg("MULTIPLE DUMP found, this needs to be merged before continuing!");
                    }
                    
                }
                logMsg("End of multiple move log \n");
                unlink('move.log');
                $i++;
                
            }
           # Join multipart dumps
            if ($joinDumps && scalar(@parts) > 1)
            {
                $multipartIndex++;
                my $joinedDumpName = "joined.".$dump.".".$multipartIndex.".dmp";
                my $rv = join_dumps($moveLocation, \@parts, $joinedDumpName);
                if ($rv)
                {
                    my $oldKey = $parts[0];
                    delete $movedDumps{$oldKey};
                    $movedDumps{$joinedDumpName} = 1;
                }
            }
        }
    }
    
    my @returnList = keys(%movedDumps);
    
    logMsg("TDUMP Summary:");
    foreach my $line (@returnList)
    {
        print("$line \n");
    }
    logMsg("End of TDUMP Summary");
    
    return (@returnList);
    
}

# Re-join the parts of a multipart tdump
# On failure, the joined dump will be deleted.
# parameters: $sourceDir - where the dump parts are
#             $dumpNames - a reference to an ordered array of dump parts
#             $newName - the name for the joined dump

sub join_dumps {
    
    my ($sourceDir, $dumpNames, $newName) = @_;
    
    logMsg("Attempting to join dump parts: " . join(',', @$dumpNames) . " to file $newName");
    
    my $outputName = "$sourceDir/$newName";
    
    my $seek = 0;
    foreach my $dumpName (@$dumpNames) {
        logMsg("joining dump part $dumpName");
        my $command = "dd if=$sourceDir/$dumpName of=$outputName bs=4160";
        if ($seek) {
            $command = $command . " seek=$seek";
        }
        logMsg("Running command '$command'");
        my $output = `$command 2>&1`;
        if ($output =~ m/(\d+)\+(\d)+ records out/) {
            my $blocksWritten = $1;
            my $extraBytesWritten = $2;
            logMsg("seems to have worked, $blocksWritten blocks, $extraBytesWritten bytes");
            if ($extraBytesWritten ne "0") {
                logMsg("Number of blocks written wasn't a whole number. Can't cope !! Argh. Deleting output file");
                `rm $outputName`;
                return 0;
            }
            $seek = $seek + $blocksWritten;
        } else {
            logMsg("dd command appears to have failed. Output was\n$output\nRemoving output file $outputName");
            `rm $outputName`;
            return 0;
        }
    }
    
    return 1;
}

1;
