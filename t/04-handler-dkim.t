#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper;

use Mail::Milter::Authentication::Tester::HandlerTester;
use Mail::Milter::Authentication::Constants qw{ :all };
use Test::Exception;
use Test::More;
use Crypt::OpenSSL::RSA;
use Mail::DKIM::Signer;
use Mail::DKIM::TextWrap;
use Mail::DKIM::PrivateKey;

my $basedir = q{};

open( STDERR, '>>', $basedir . 't/tmp/misc.err' ) || die "Cannot open errlog [$!]";
#open( STDOUT, '>>', $basedir . 't/tmp/misc.err' ) || die "Cannot open errlog [$!]";

my $ZoneData = q{};
my $KeyData = {};

my @algorithms = qw{ rsa-sha1 rsa-sha256 };
my @sizes = qw{ 512 1024 2048 };
my @methods = qw{ simple relaxed };
my $TestMail = 'From: test@example.com
To: test@example.com
Subject: Test

This is a test';

foreach my $algorithm ( @algorithms ) {
    foreach my $size ( @sizes ) {
        foreach my $method ( @methods ) {
            my $name = 'sel' . $algorithm . $size . $method;
            add_key({ 'name' => $name, 'size' => $size, 'domain' => 'example.com', 'selector' => $name, 'algorithm' => $algorithm, 'method' => $method });
        }
    }
}

foreach my $Key ( sort keys %$KeyData ) {
    $ZoneData .= $KeyData->{$Key}->{'selector'} . '._domainkey.' . $KeyData->{$Key}->{'domain'} . '. 2600 IN TXT "v=DKIM1; k=rsa; p=' . $KeyData->{$Key}->{'public'} . "\"\n";
}

my $TestWith = {
    'connect_ip' => '1.2.3.4',
    'connect_name' => 'mx.example.com',
    'helo' => 'mx.example.com',
    'mailfrom' => 'test@example.com',
    'rcptto' => [ 'test@example.com' ],
};

my $testers = {
    'hide_none' => Mail::Milter::Authentication::Tester::HandlerTester->new({
        'protocol' => 'milter',
        'prefix'   => $basedir . 't/config/handler/etc',
        'zonedata' => $ZoneData,
        'handler_config' => {
            'DKIM' => { 'hide_none' => 1 },
        },
    }),
    'basic' => Mail::Milter::Authentication::Tester::HandlerTester->new({
        'protocol' => 'milter',
        'prefix'   => $basedir . 't/config/handler/etc',
        'zonedata' => $ZoneData,
        'handler_config' => {
            'DKIM' => {},
        },
    }),
    'extra_properties' => Mail::Milter::Authentication::Tester::HandlerTester->new({
        'protocol' => 'milter',
        'prefix'   => $basedir . 't/config/handler/etc',
        'zonedata' => $ZoneData,
        'handler_config' => {
            'DKIM' => { 'extra_properties' => 1 },
        },
    }),
};

subtest 'none hidden' => sub {
    my $tester = $testers->{ 'hide_none' };
    $TestWith->{ 'body' } = $TestMail;
    $tester->run( $TestWith );
    my $header = $tester->get_authresults_header()->search({ 'key' => 'dkim' });
    is( scalar @{ $header->children() }, 0, 'No Entry' );
};

subtest 'none shown' => sub {
    my $tester = $testers->{ 'basic' };
    $TestWith->{ 'body' } = $TestMail;
    $tester->run( $TestWith );
    my $header = $tester->get_authresults_header()->search({ 'key' => 'dkim' });
    is( scalar @{ $header->children() }, 1, 'One Entry' );
    my $result = eval{ $header->children()->[0]->value(); } // q{};
    is( $result, 'none', 'DKIM None');
};

foreach my $tester_key ( sort keys %$testers ) {
    my $tester = $testers->{ $tester_key };

    subtest 'Single signing pass ' . $tester_key => sub {
        # Single Key Testing
        foreach my $Key ( sort keys %$KeyData ) {
            my $SignedMail = sign_mail({ 'mail' => $TestMail, 'key' => $Key });
            $TestWith->{ 'body' } = $SignedMail;
            $tester->run( $TestWith );
            my $header = $tester->get_authresults_header()->search({ 'key' => 'dkim' });
            is( scalar @{ $header->children() }, 1, 'One Entry' );
            my $result = eval{ $header->children()->[0]->value(); } // q{};
            is( $result, 'pass', 'DKIM Pass on ' . $Key );
            if ( $tester_key eq 'extra_properties' ) {
                is ( $header->search({ 'key' => 'x-bits' })->children()->[0]->value(), $KeyData->{ $Key }->{ 'size' }, 'Size property' );
                is ( $header->search({ 'key' => 'x-keytype' })->children()->[0]->value(), 'rsa', 'Key Type property' );
                is ( 'rsa-' . $header->search({ 'key' => 'x-algorithm' })->children()->[0]->value(), $KeyData->{ $Key }->{ 'algorithm' }, 'Algorithm property' );
                is ( $header->search({ 'key' => 'x-selector' })->children()->[0]->value(), $KeyData->{ $Key }->{ 'selector' }, 'Selector property' );
            }
            else {
                is ( scalar @{ $header->search({ 'key' => 'x-bits' })->children() }, 0, 'No x-bits entry' );
                is ( scalar @{ $header->search({ 'key' => 'x-keytype' })->children() }, 0, 'No x-keytype entry' );
                is ( scalar @{ $header->search({ 'key' => 'x-algoeithm' })->children() }, 0, 'No x-algorithm entry' );
                is ( scalar @{ $header->search({ 'key' => 'x-selector' })->children() }, 0, 'No x-selector entry' );
            }
        }
    };

}

my $tester = $testers->{ 'basic' };

subtest 'Single signing fail' => sub {
    # Single Key Testing
    foreach my $Key ( sort keys %$KeyData ) {
        my $SignedMail = sign_mail({ 'mail' => $TestMail, 'key' => $Key });
        $SignedMail .= "\nWith added text for a fail result\n";
        $TestWith->{ 'body' } = $SignedMail;
        $tester->run( $TestWith );
        my $header = $tester->get_authresults_header()->search({ 'key' => 'dkim' });
        is( scalar @{ $header->children() }, 1, 'One Entry' );
        my $result = eval{ $header->children()->[0]->value(); } // q{};
        is( $result, 'fail', 'DKIM Fail on ' . $Key );
    }
};

subtest 'Double signing pass' => sub {
    # Double Key Testing
    foreach my $Key ( sort keys %$KeyData ) {
        foreach my $Key2 ( sort keys %$KeyData ) {
            my $SignedMail = sign_mail({ 'mail' => $TestMail, 'key' => $Key });
            my $SignedMail2 = sign_mail({ 'mail' => $SignedMail, 'key' => $Key2 });
            $TestWith->{ 'body' } = $SignedMail2;
            $tester->run( $TestWith );
            my $header = $tester->get_authresults_header()->search({ 'key' => 'dkim' });
            is( scalar @{ $header->children() }, 2, 'Two Entries' );
            my $result = eval{ $header->children()->[0]->value(); } // q{};
            is( $result, 'pass', 'First DKIM Pass on ' . $Key . ' and ' . $Key2 );
            my $result2 = eval{ $header->children()->[1]->value(); } // q{};
            is( $result2, 'pass', 'Second DKIM Pass on ' . $Key . ' and ' . $Key2 );
        }
    }
};

subtest 'Double signing single pass' => sub {
    # Double Key Testing
    foreach my $Key ( sort keys %$KeyData ) {
        foreach my $Key2 ( sort keys %$KeyData ) {
            my $SignedMail = sign_mail({ 'mail' => $TestMail, 'key' => $Key });
            $SignedMail .= "\nWith added text for a fail result\n";
            my $SignedMail2 = sign_mail({ 'mail' => $SignedMail, 'key' => $Key2 });
            $TestWith->{ 'body' } = $SignedMail2;
            $tester->run( $TestWith );
            my $header = $tester->get_authresults_header()->search({ 'key' => 'dkim' });
            is( scalar @{ $header->children() }, 2, 'Two Entries' );
            my $header_pass = $tester->get_authresults_header()->search({ 'key' => 'dkim', 'value' => 'pass' });
            my $result_pass = eval{ $header->children()->[0]->value(); } // q{};
            is( $result_pass, 'pass', 'DKIM Pass on ' . $Key . ' and ' . $Key2 );
            my $header_fail = $tester->get_authresults_header()->search({ 'key' => 'dkim', 'value' => 'fail' });
            my $result_fail = eval{ $header->children()->[0]->value(); } // q{};
            is( $result_fail, 'pass', 'DKIM Fail on ' . $Key . ' and ' . $Key2 );
        }
    }
};

done_testing();

sub sign_mail {

    my ( $Args ) = @_;

    my $mail = $Args->{'mail'};
    my $key = $Args->{'key'};

    my $dkim = Mail::DKIM::Signer->new(
        Algorithm => $KeyData->{$key}->{'algorithm'},
        Method =>  $KeyData->{$key}->{'method'},
        Domain =>  $KeyData->{$key}->{'domain'},
        Selector =>  $KeyData->{$key}->{'selector'},
        Key =>  $KeyData->{$key}->{'private'},
    );

    my $signedmail = q{};

    my @allmail = split "\n", $mail;
    foreach my $line ( @allmail ) {
        chomp $line;
        $line =~ s/\015$//;
        $dkim->PRINT("$line\015\012");
        $signedmail .= "$line\015\012";
    }
    $dkim->CLOSE;

    my $signature = $dkim->signature;
    return $signature->as_string . "\015\012" . $signedmail;
}

sub add_key {
    my ( $Args ) = @_;

    my $RSA = Crypt::OpenSSL::RSA->generate_key( $Args->{'size'} );
    my $DKIMPrivate = $RSA->get_private_key_string();
    my $DKIMPublic = $RSA->get_public_key_x509_string();

    my @DKIMPublic = split(m/\n/m, $DKIMPublic);
    @DKIMPublic = @DKIMPublic[1 .. ($#DKIMPublic - 1)];
    $DKIMPublic = join('', @DKIMPublic);
    my @DKIMPrivate = split(m/\n/m, $DKIMPrivate);
    @DKIMPrivate = @DKIMPrivate[1 .. ($#DKIMPrivate - 1)];
    $DKIMPrivate = join('', @DKIMPrivate);
    $DKIMPrivate = Mail::DKIM::PrivateKey->load( 'Data' => $DKIMPrivate );

    $KeyData->{ $Args->{ 'name' } } = {
        'size' => $Args->{ 'size' },
        'public' => $DKIMPublic,
        'private' => $DKIMPrivate,
        'domain' => $Args->{'domain'},
        'selector' => $Args->{'selector'},
        'algorithm' => $Args->{'algorithm'},
        'method' => $Args->{'method'},
    };

    return;
}

# Need to add
# domainkeys
# adsp
# garbage in Signature header
# garbage in DNS record
# missing DNS record
# modified headers
