package Koha::Plugin::Com::ByWaterSolutions::PayViaFIS::API;

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use WWW::Form::UrlEncoded qw(parse_urlencoded);

our $ENABLE_DEBUGGING = 1;

sub handle_payment {
    warn "Koha::Plugin::Com::ByWaterSolutions::PayViaFIS::API::handle_payment" if $ENABLE_DEBUGGING;
    my $c = shift->openapi->valid_input or return;

    my $params = $c->req->params->to_hash;
    warn "FIS: PARAMS: " . Data::Dumper::Dumper($params) if $ENABLE_DEBUGGING;

    my $transaction_id = $params->{FISTransactionNumber};
    my $borrowernumber = $params->{UserPart3} || $params->{BorrowerNumber};
    my $MerchantCode = $params->{MerchantCode};
    my $SettleCode = $params->{SettleCode};

    my $li = $params->{LineItems};
    $li =~ s/^\s+|\s+$//g;
    my @line_items = split( /\,?\[(.*)\]\n?/, $li );
    @line_items = grep { $_ ne q{} } @line_items;

    warn "FIS: TRANSACTION ID: $transaction_id" if $ENABLE_DEBUGGING;

    my $merchant_code =
      C4::Context->preference('FisMerchantCode');    #33WSH-LIBRA-PDWEB-W
    my $settle_code =
      C4::Context->preference('FisSettleCode');      #33WSH-LIBRA-PDWEB-00
    my $password = C4::Context->preference('FisApiPassword');    #testpass;

    return $c->render(
        status  => 500,
        openapi => { error => 'invalid_merchant_code' }
    ) unless ( $merchant_code eq $MerchantCode );

    return $c->render(
        status  => 500,
        openapi => { error => 'invalid_settle_code' }
    ) unless ( $settle_code eq $SettleCode );

    my $note = "FIS: $transaction_id";

    return $c->render(
        status  => 500,
        openapi => { error => 'duplicate_payment' }
      )
      if Koha::Account::Lines->search(
        { borrowernumber => $borrowernumber, note => $note } )->count();

    warn "FIS: LINE ITEMS - " . Data::Dumper::Dumper( \@line_items )
      if $ENABLE_DEBUGGING;

    my @paid;
    warn "FIS: BORROWERNUMBER - $borrowernumber" if $ENABLE_DEBUGGING;
    my $account = Koha::Account->new( { patron_id => $borrowernumber } );
    foreach my $l (@line_items) {
        warn "FIS: LINE ITEM - ***$l***" if $ENABLE_DEBUGGING;
        $l =~ s/^\s+|\s+$//g;
        my ( $i, $id, $description, $amount ) = split( /\*/, $l );

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
