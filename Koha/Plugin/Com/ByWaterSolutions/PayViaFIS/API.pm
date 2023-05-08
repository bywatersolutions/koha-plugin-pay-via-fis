package Koha::Plugin::Com::ByWaterSolutions::PayViaFIS::API;

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use WWW::Form::UrlEncoded qw(parse_urlencoded);

our $ENABLE_DEBUGGING = 0;

sub handle_payment {
    my $c = shift->openapi->valid_input or return;

    my $params = $c->req->params->to_hash;
    warn "PARAMS: " . Data::Dumper::Dumper($params) if $ENABLE_DEBUGGING;

    my $transaction_id = $params->{TransactionId};
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

    return $c->render(
        status  => 500,
        openapi => { error => $$response->status_line }
    ) unless $response->is_success;

    my ( $m, $v );

    warn "FIS: RESPONSE CONTENT - ***" . $response->decoded_content . "***"
      if $ENABLE_DEBUGGING;

    my @params = split( '&', uri_unescape( $response->decoded_content ) );
    foreach my $p (@params) {
        my ( $key, $value ) = split( '=', $p );
        $params->{$key} = $value // q{};
    }

    warn "FIS: INCOMING PARAMS - " . Data::Dumper::Dumper($params)
      if $ENABLE_DEBUGGING;

    return $c->render(
        status  => 500,
        openapi => { error => 'invalid_payment' }
    ) unless $params->{TransactionID} eq $transaction_id;

    my $borrowernumber = $params->{UserPart3};
    my $note           = "FIS: $transaction_id";

    return $c->render(
        status  => 500,
        openapi => { error => 'duplicate_payment' }
      )
      if Koha::Account::Lines->search(
        { borrowernumber => $borrowernumber, note => $note } )->count();

    my @line_items = split( /,/, $params->{LineItems} );
    warn "FIS: LINE ITEMS - " . Data::Dumper::Dumper( \@line_items )
      if $ENABLE_DEBUGGING;

    my @paid;
    my $account = Koha::Account->new( { patron_id => $borrowernumber } );
    foreach my $l (@line_items) {
        warn "FIS: LINE ITEM - ***$l***" if $ENABLE_DEBUGGING;
        $l = substr( $l, 1, length($l) - 2 );
        my ( undef, $id, $description, $amount ) =
          split( /[\*,\~]/, $l );

        warn "FIS: ACCOUNTLINE TO PAY ID - $id" if $ENABLE_DEBUGGING;
        warn "FIS: DESC - $description"         if $ENABLE_DEBUGGING;
        warn "FIST: AMOUNT - $amount"           if $ENABLE_DEBUGGING;

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
                amount => $amount,
                lines  => [ scalar Koha::Account::Lines->find($id) ],
                note   => $note,
            }
        );
    }

    return $c->render(
        status  => 200,
        openapi => { 'valid_payment' => $params->{TransactionAmount} }
    );
}

1;
