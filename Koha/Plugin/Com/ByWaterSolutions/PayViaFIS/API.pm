package Koha::Plugin::Com::ByWaterSolutions::PayViaFIS::API;

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use Koha::Plugin::Com::ByWaterSolutions::PayViaFIS;

use WWW::Form::UrlEncoded qw(parse_urlencoded);

sub handle_payment {
    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PayViaFIS->new();
    my $debug  = $plugin->_debugging_enabled;

    warn "Koha::Plugin::Com::ByWaterSolutions::PayViaFIS::API::handle_payment" if $debug;
    my $c = shift->openapi->valid_input or return;

    my $params = $c->req->params->to_hash;
    warn "FIS: PARAMS: " . Data::Dumper::Dumper($params) if $debug;

    my $transaction_id = $params->{FISTransactionNumber};
    my $borrowernumber = $params->{UserPart3} || $params->{BorrowerNumber};
    my $MerchantCode = $params->{MerchantCode};
    my $SettleCode = $params->{SettleCode};

    my $li = $params->{LineItems};
    $li =~ s/^\s+|\s+$//g;
    my @line_items = split( /\,?\[(.*)\]\n?/, $li );
    @line_items = grep { $_ ne q{} } @line_items;

    warn "FIS: TRANSACTION ID: $transaction_id" if $debug;

    # The API password is not part of this check - FIS does not send it back to us
    my $merchant_code = $plugin->retrieve_data('FisMerchantCode');    #33WSH-LIBRA-PDWEB-W
    my $settle_code   = $plugin->retrieve_data('FisSettleCode');      #33WSH-LIBRA-PDWEB-00

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
      if $debug;

    my @paid;
    warn "FIS: BORROWERNUMBER - $borrowernumber" if $debug;
    my $account = Koha::Account->new( { patron_id => $borrowernumber } );
    foreach my $l (@line_items) {
        warn "FIS: LINE ITEM - ***$l***" if $debug;
        $l =~ s/^\s+|\s+$//g;
        my ( $i, $id, $description, $amount ) = split( /\*/, $l );

        warn "FIS: ACCOUNTLINE TO PAY ID - $id" if $debug;
        warn "FIS: DESC - $description"         if $debug;
        warn "FIST: AMOUNT - $amount"           if $debug;

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
