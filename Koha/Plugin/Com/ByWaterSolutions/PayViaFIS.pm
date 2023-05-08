package Koha::Plugin::Com::ByWaterSolutions::PayViaFIS;

use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth qw(get_template_and_user);
use Koha::Account;
use Koha::Account::Lines;

use JSON qw(decode_json);
use LWP::UserAgent;
use URI::Escape qw(uri_unescape);

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'Pay Via FIS PayDirect',
    author => 'Kyle M Hall',
    description => 'This plugin enables online OPAC fee payments via FIS PayDirect',
    date_authored   => '2017-08-24',
    date_updated    => '1900-01-01',
    minimum_version => '16.06.00.018',
    maximum_version => undef,
    version         => $VERSION,
};

our $ENABLE_DEBUGGING = 1;

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    return $self->retrieve_data('enable_opac_payments') eq 'Yes';
}

sub opac_online_payment_begin {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = get_template_and_user(
        {   template_name   => $self->mbf_path('opac_online_payment_begin.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my @accountline_ids = $cgi->multi_param('accountline');

    my $rs = Koha::Database->new()->schema()->resultset('Accountline');
    my @accountlines = map { $rs->find($_) } @accountline_ids;

    $template->param(
        borrower             => scalar Koha::Patrons->find($borrowernumber),
        payment_method       => scalar $cgi->param('payment_method'),
        enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
        FisPostUrl           => $self->retrieve_data('FisPostUrl'),
        FisMerchantCode      => $self->retrieve_data('FisMerchantCode'),
        FisSettleCode        => $self->retrieve_data('FisSettleCode'),
        FisApiUrl            => $self->retrieve_data('FisApiUrl'),
        FisApiPassword       => $self->retrieve_data('FisApiPassword'),
        accountlines         => \@accountlines,
    );


    print $cgi->header();
    print $template->output();
}

sub opac_online_payment_end {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name => $self->mbf_path('opac_online_payment_end.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );
    warn "FIS: BORROWERNUMBER - $borrowernumber" if $ENABLE_DEBUGGING;

    my $transaction_id = $cgi->param('TransactionId');
    warn "FIS: TRANSACTION ID: $transaction_id";

    my $merchant_code =
      C4::Context->preference('FisMerchantCode');    #33WSH-LIBRA-PDWEB-W
    my $settle_code =
      C4::Context->preference('FisSettleCode');      #33WSH-LIBRA-PDWEB-00
    my $password = C4::Context->preference('FisApiPassword');    #testpass;

    my $ua  = LWP::UserAgent->new;
    my $url = C4::Context->preference('FisApiUrl')
      ;    #https://paydirectapi.ca.link2gov.com/ProcessTransactionStatus;
    my $response = $ua->post(
        $url,
        {
            L2GMerchantCode       => $merchant_code,
            Password              => $password,
            SettleMerchantCode    => $settle_code,
            OriginalTransactionId => $transaction_id,
        }
    );

    my ( $m, $v );

    if ( $response->is_success ) {
        warn "FIS: RESPONSE CONTENT - ***" . $response->decoded_content . "***" if $ENABLE_DEBUGGING;
        my @params = split( '&', uri_unescape( $response->decoded_content ) );
        my $params;
        foreach my $p (@params) {
            my ( $key, $value ) = split( '=', $p );
            $params->{$key} = $value // q{};
        }
        warn "FIS: INCOMING PARAMS - " . Data::Dumper::Dumper( $params ) if $ENABLE_DEBUGGING;

        if ( $params->{TransactionID} eq $transaction_id ) {

            my $note = "FIS: $transaction_id";

            unless ( Koha::Account::Lines->search( { borrowernumber => $borrowernumber, note => $note } )->count() ) {

                my @line_items = split( /,/, $cgi->param('LineItems') );
                warn "FIS: LINE ITEMS - " . Data::Dumper::Dumper( \@line_items ) if $ENABLE_DEBUGGING;

                my @paid;
                my $account = Koha::Account->new( { patron_id => $borrowernumber } );
                foreach my $l (@line_items) {
                    warn "FIS: LINE ITEM - ***$l***" if $ENABLE_DEBUGGING;
                    $l = substr( $l, 1, length($l) - 2 );
                    my ( undef, $id, $description, $amount ) =
                      split( /[\*,\~]/, $l );

                    warn "FIS: ACCOUNTLINE TO PAY ID - $id" if $ENABLE_DEBUGGING;
                    warn "FIS: DESC - $description" if $ENABLE_DEBUGGING;
                    warn "FIST: AMOUNT - $amount" if $ENABLE_DEBUGGING;

                    push(
                        @paid,
                        {
                            accountlines_id => $id,
                            description     => $description,
                            amount          => $amount
                        }
                    );

                    $account->pay(
                        {
                            amount     => $amount,
                            lines      => [ scalar Koha::Account::Lines->find($id) ],
                            note       => $note,
                        }
                    );
                }

                $m = 'valid_payment';
                $v = $params->{TransactionAmount};
            }
            else {
                $m = 'duplicate_payment';
                $v = $transaction_id;
            }
        }
        else {
            $m = 'invalid_payment';
            $v = $transaction_id;
        }
    }
    else {
        die( $response->status_line );
    }

    $template->param(
        borrower      => scalar Koha::Patrons->find($borrowernumber),
        message       => $m,
        message_value => $v,
    );

    print $cgi->header();
    print $template->output();
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
            FisPostUrl      => $self->retrieve_data('FisPostUrl'),
            FisMerchantCode => $self->retrieve_data('FisMerchantCode'),
            FisSettleCode   => $self->retrieve_data('FisSettleCode'),
            FisApiUrl       => $self->retrieve_data('FisApiUrl'),
            FisApiPassword  => $self->retrieve_data('FisApiPassword'),
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                FisPostUrl         => $cgi->param('FisPostUrl'),
                FisMerchantCode    => $cgi->param('FisMerchantCode'),
                FisSettleCode      => $cgi->param('FisSettleCode'),
                FisApiUrl          => $cgi->param('FisApiUrl'),
                FisApiPassword     => $cgi->param('FisApiPassword'),
            }
        );
        $self->go_home();
    }
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'fis';
}

sub install() {
    return 1;
}

sub uninstall() {
    return 1;
}

1;
