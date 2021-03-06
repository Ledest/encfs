#!/usr/bin/perl -w

# Test EncFS --reverse mode

use warnings;
use Test::More tests => 26;
use File::Path;
use File::Temp;
use IO::Handle;
use Errno qw(EROFS);

require("tests/common.pl");

my $tempDir = $ENV{'TMPDIR'} || "/tmp";

# Helper function
# Create a new empty working directory
sub newWorkingDir
{
    our $workingDir = mkdtemp("$tempDir/encfs-reverse-tests-XXXX")
        || BAIL_OUT("Could not create temporary directory");

    our $plain = "$workingDir/plain";
    mkdir($plain);
    our $ciphertext = "$workingDir/ciphertext";
    mkdir($ciphertext);
    our $decrypted = "$workingDir/decrypted";
    mkdir($decrypted);
}

# Helper function
# Unmount and delete mountpoint
sub cleanup
{
    system("fusermount -u $decrypted");
    system("fusermount -u $ciphertext");
    our $workingDir;
    rmtree($workingDir);
    ok( ! -d $workingDir, "working dir removed");
}

# Helper function
# Mount encryption-decryption chain
#
# Directory structure: plain -[encrypt]-> ciphertext -[decrypt]-> decrypted
sub mount
{
    delete $ENV{"ENCFS6_CONFIG"};
    system("./encfs/encfs --extpass=\"echo test\" --standard $plain $ciphertext --reverse");
    ok(waitForFile("$plain/.encfs6.xml"), "plain .encfs6.xml exists") or BAIL_OUT("'$plain/.encfs6.xml'");
    my $e = encName(".encfs6.xml");
    ok(waitForFile("$ciphertext/$e"), "encrypted .encfs6.xml exists") or BAIL_OUT("'$ciphertext/$e'");
    system("ENCFS6_CONFIG=$plain/.encfs6.xml ./encfs/encfs --nocache --extpass=\"echo test\" $ciphertext $decrypted");
    ok(waitForFile("$decrypted/.encfs6.xml"), "decrypted .encfs6.xml exists") or BAIL_OUT("'$decrypted/.encfs6.xml'");
}

# Helper function
#
# Get encrypted name for file
sub encName
{
	my $name = shift;
	my $enc = qx(ENCFS6_CONFIG=$plain/.encfs6.xml ./encfs/encfsctl encode --extpass="echo test" $ciphertext $name);
	chomp($enc);
	return $enc;
}

# Copy a directory tree and verify that the decrypted data is identical
sub copy_test
{
    ok(system("cp -a encfs $plain")==0, "copying files to plain");
    ok(system("diff -r -q $plain $decrypted")==0, "decrypted files are identical");
    ok(-f "$plain/encfs/encfs.cpp", "file exists");
    unlink("$plain/encfs/encfs.cpp");
    ok(! -f "$decrypted/encfs.cpp", "file deleted");
}

# Create symlinks and verify they are correctly decrypted
# Parameter: symlink target
sub symlink_test
{
    my $target = shift;
    symlink($target, "$plain/symlink");
    $dec = readlink("$decrypted/symlink");
    ok( $dec eq $target, "symlink to '$target'") or
        print("# (original) $target' != '$dec' (decrypted)\n");
    unlink("$plain/symlink");
}

# Grow a file from 0 to x kB and
# * check the ciphertext length is correct (stat + read)
# * check that the decrypted length is correct (stat + read)
# * check that plaintext and decrypted are identical
sub grow {
    # pfh ... plaintext file handle
    open(my $pfh, ">", "$plain/grow");
    # vfh ... verification file handle
    open(my $vfh, "<", "$plain/grow");
    $pfh->autoflush;
    # ciphertext file name
    my $cname = encName("grow");
    # cfh ... ciphertext file handle
    ok(open(my $cfh, "<", "$ciphertext/$cname"), "open ciphertext grow file");
    # dfh ... decrypted file handle
    ok(open(my $dfh, "<", "$decrypted/grow"), "open decrypted grow file");

    # csz ... ciphertext size
    ok(sizeVerify($cfh, 0), "ciphertext of empty file is empty");
    ok(sizeVerify($dfh, 0), "decrypted empty file is empty");

    my $ok = 1;
    my $max = 9000;
    for($i=5; $i < $max; $i += 5)
    {
        print($pfh "abcde") or die("write failed");
        # autoflush should make sure the write goes to the kernel
        # immediately. Just to be sure, check it here.
        sizeVerify($vfh, $i) or die("unexpected plain file size");
        sizeVerify($cfh, $i+8) or $ok = 0;
        sizeVerify($dfh, $i) or $ok = 0;
        
        if(md5fh($vfh) ne md5fh($dfh))
        {
            $ok = 0;
            print("# content is different, unified diff:\n");
            system("diff -u $plain/grow $decrypted/grow");
        }

        last unless $ok;
    }
    ok($ok, "ciphertext and decrypted size of file grown to $i bytes");
}

sub largeRead {
    writeZeroes("$plain/largeRead", 1024*1024);
    # ciphertext file name
    my $cname = encName("largeRead");
    # cfh ... ciphertext file handle
    ok(open(my $cfh, "<", "$ciphertext/$cname"), "open ciphertext largeRead file");
    ok(sizeVerify($cfh, 1024*1024+8), "1M file size");
}

# Check that the reverse mount is read-only
# (writing is not supported in reverse mode because of the added
#  complexity and the marginal use case)
sub writesDenied {
    $fn = "$plain/writesDenied";
    writeZeroes($fn, 1024);
    my $efn = $ciphertext . "/" . encName("writesDenied");
    open(my $fh, ">", $efn);
    if( ok( $! == EROFS, "open for write denied, EROFS")) {
        ok( 1, "writing denied, filehandle not open");
    }
    else {
        print($fh "foo");
        ok( $! == EROFS, "writing denied, EROFS");
    }
    $target = $ciphertext . "/" . encName("writesDenied2");
    rename($efn, $target);
    ok( $! == EROFS, "rename denied, EROFS") or die();
    unlink($efn);
    ok( $! == EROFS, "unlink denied, EROFS");
    utime(undef, undef, $efn) ;
    ok( $! == EROFS, "touch denied, EROFS");
    truncate($efn, 10);
    ok( $! == EROFS, "truncate denied, EROFS");
}

# Setup mounts
newWorkingDir();
mount();

# Actual tests
grow();
largeRead();
copy_test();
symlink_test("/"); # absolute
symlink_test("foo"); # relative
symlink_test("/1/2/3/4/5/6/7/8/9/10/11/12/13/14/15/15/17/18"); # long
symlink_test("!§\$%&/()\\<>#+="); # special characters
symlink_test("$plain/foo");
writesDenied();

# Umount and delete files
cleanup();
