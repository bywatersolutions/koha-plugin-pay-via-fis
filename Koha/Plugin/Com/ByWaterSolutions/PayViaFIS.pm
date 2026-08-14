package Koha::Plugin::Com::ByWaterSolutions::PayViaFIS;

use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth qw(get_template_and_user);
use Koha::Account;
use Koha::Account::Lines;

use Koha::Config::SysPrefs;

use Encode qw(decode_utf8 encode_utf8);
use JSON qw(decode_json);
use LWP::UserAgent;
use URI::Escape qw(uri_unescape);
use Digest::SHA qw(sha256_hex);
use Try::Tiny;

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

# Encrypted credentials are stored with this marker in front of the ciphertext so we can
# tell them apart from cleartext values left behind by versions before encryption existed.
our $ENCRYPTION_PREFIX = 'koha-enc-v1:';

# Every setting this plugin holds. These used to be read from system preferences on the
# payment path while the configuration page wrote them to plugin_data, so the two could
# never agree. plugin_data is now the only source, and upgrade() migrates the old prefs.
our @CONFIG_KEYS = qw( FisPostUrl FisMerchantCode FisSettleCode FisApiUrl FisApiPassword );

# The subset of the above holding secrets, which must be encrypted at rest
our @CREDENTIAL_KEYS = qw( FisApiPassword );

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

    return 1;
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
        FisPostUrl           => $self->retrieve_data('FisPostUrl'),
        FisMerchantCode      => $self->retrieve_data('FisMerchantCode'),
        FisSettleCode        => $self->retrieve_data('FisSettleCode'),
        FisApiUrl            => $self->retrieve_data('FisApiUrl'),
        accountlines         => \@accountlines,
    );


    print $cgi->header();
    print $template->output();
}

sub opac_online_payment_end {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $debug = $self->_debugging_enabled;

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name => $self->mbf_path('opac_online_payment_end.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );
    warn "FIS: BORROWERNUMBER - $borrowernumber" if $debug;

    my $transaction_id = $cgi->param('TransactionId');
    warn "FIS: TRANSACTION ID: $transaction_id" if $debug;

    my $merchant_code = $self->retrieve_data('FisMerchantCode');    #33WSH-LIBRA-PDWEB-W
    my $settle_code   = $self->retrieve_data('FisSettleCode');      #33WSH-LIBRA-PDWEB-00
    my $password      = $self->_get_secret('FisApiPassword');       #testpass;

    my $ua  = LWP::UserAgent->new;
    my $url = $self->retrieve_data('FisApiUrl')
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
        warn "FIS: RESPONSE CONTENT - ***" . $response->decoded_content . "***" if $debug;
        my @params = split( '&', uri_unescape( $response->decoded_content ) );
        my $params;
        foreach my $p (@params) {
            my ( $key, $value ) = split( '=', $p );
            $params->{$key} = $value // q{};
        }
        warn "FIS: INCOMING PARAMS - " . Data::Dumper::Dumper( $params ) if $debug;

        if ( $params->{TransactionID} eq $transaction_id ) {

            my $note = "FIS: " . sha256_hex($transaction_id);

            unless ( Koha::Account::Lines->search( { borrowernumber => $borrowernumber, note => $note } )->count() ) {

                my @line_items = split( /,/, $cgi->param('LineItems') );
                warn "FIS: LINE ITEMS - " . Data::Dumper::Dumper( \@line_items ) if $debug;

                my @paid;
                my $account = Koha::Account->new( { patron_id => $borrowernumber } );
                foreach my $l (@line_items) {
                    warn "FIS: LINE ITEM - ***$l***" if $debug;
                    $l = substr( $l, 1, length($l) - 2 );
                    my ( undef, $id, $description, $amount ) =
                      split( /[\*,\~]/, $l );

                    warn "FIS: ACCOUNTLINE TO PAY ID - $id" if $debug;
                    warn "FIS: DESC - $description" if $debug;
                    warn "FIST: AMOUNT - $amount" if $debug;

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

    # An instance that had no encryption key when the plugin was upgraded still holds its
    # credentials in cleartext, so try again every time someone opens the configuration page
    $self->_migrate_sysprefs_to_plugin_data;
    $self->_encrypt_stored_credentials;

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        my $stored_password = $self->retrieve_data('FisApiPassword');

        ## Grab the values we already have for our settings, if any exist
        ## The API password itself is deliberately never sent to the template
        $template->param(
            FisPostUrl      => $self->retrieve_data('FisPostUrl'),
            FisMerchantCode => $self->retrieve_data('FisMerchantCode'),
            FisSettleCode   => $self->retrieve_data('FisSettleCode'),
            FisApiUrl       => $self->retrieve_data('FisApiUrl'),
            FisApiPassword_is_set => ( defined $stored_password && length $stored_password ) ? 1 : 0,
            FisApiPassword_is_encrypted =>
                ( $stored_password && index( $stored_password, $ENCRYPTION_PREFIX ) == 0 ) ? 1 : 0,
            encryption_available => $self->_encryption ? 1 : 0,
            csrf_token           => $self->_csrf_token,
            EnableDebugging      => $self->retrieve_data('EnableDebugging') ? 1 : 0,
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        # An empty password field means "keep the current password", so _set_secret ignores it
        $self->_set_secret( 'FisApiPassword', scalar $cgi->param('FisApiPassword') );

        $self->store_data(
            {
                FisPostUrl         => $cgi->param('FisPostUrl'),
                FisMerchantCode    => $cgi->param('FisMerchantCode'),
                FisSettleCode      => $cgi->param('FisSettleCode'),
                FisApiUrl          => $cgi->param('FisApiUrl'),

                # An unchecked checkbox submits nothing, so store the absence as a 0
                EnableDebugging    => $cgi->param('EnableDebugging') ? 1 : 0,
            }
        );
        $self->go_home();
    }
}

=head3 _debugging_enabled

    warn "..." if $self->_debugging_enabled;

True when debug logging has been switched on from the configuration page. Off unless switched
on: it dumps the whole FIS API response, which is verbose and may carry data we would rather
not leave in the web server log for however long the host's logrotate policy keeps it.

Cached per object so a request that logs a dozen lines doesn't make a dozen trips to the
database.

=cut

sub _debugging_enabled {
    my ($self) = @_;

    $self->{_debugging_enabled} //= $self->retrieve_data('EnableDebugging') ? 1 : 0;

    return $self->{_debugging_enabled};
}

=head3 _encryption

    my $encryption = $self->_encryption;

Returns a Koha::Encryption object, or undef when encryption is unavailable. It is unavailable
on Koha before 22.05, and on any instance where encryption_key is unset in koha-conf.xml.

=cut

sub _encryption {
    my ($self) = @_;

    return try {
        require Koha::Encryption;
        Koha::Encryption->new;
    } catch {
        undef;
    };
}

=head3 _csrf_token

    my $token = $self->_csrf_token;

Returns a CSRF token for the configuration form, or undef on Koha versions that have no
Koha::Token. Koha::Middleware::CSRF answers any tokenless POST to the staff interface with
a 403, so the configuration form cannot be submitted without this.

=cut

sub _csrf_token {
    my ($self) = @_;

    return try {
        require Koha::Token;
        Koha::Token->new->generate_csrf( { session_id => scalar $self->{'cgi'}->cookie('CGISESSID') } );
    } catch {
        undef;
    };
}

=head3 _get_secret

    my $password = $self->_get_secret('FisApiPassword');

Returns the cleartext value of a stored credential. Values stored before encryption was added
carry no prefix and are returned as-is, so an instance without an encryption key keeps working.

=cut

sub _get_secret {
    my ( $self, $key ) = @_;

    my $stored = $self->retrieve_data($key);
    return $stored unless defined $stored && length $stored;
    return $stored unless index( $stored, $ENCRYPTION_PREFIX ) == 0;

    my $ciphertext = substr( $stored, length $ENCRYPTION_PREFIX );

    my $encryption = $self->_encryption;
    die "Pay Via FIS PayDirect: '$key' is stored encrypted but Koha's encryption is unavailable."
        . " Set 'encryption_key' in koha-conf.xml.\n"
        unless $encryption;

    my $plaintext = try {
        decode_utf8( $encryption->decrypt_hex($ciphertext) );
    } catch {
        undef;
    };

    # Decrypting with the wrong key doesn't raise an error, it just yields an empty string,
    # so an empty result has to be treated as a failure rather than as an empty credential.
    die "Pay Via FIS PayDirect: unable to decrypt '$key'. The 'encryption_key' in koha-conf.xml"
        . " may have changed. Re-enter the credential in the plugin configuration.\n"
        unless defined $plaintext && length $plaintext;

    return $plaintext;
}

=head3 _set_secret

    $self->_set_secret( 'FisApiPassword', $value );

Stores a credential, encrypted when encryption is available. An empty value is ignored so that
saving the configuration form without retyping the credential keeps the stored one.

=cut

sub _set_secret {
    my ( $self, $key, $plaintext ) = @_;

    return unless defined $plaintext && length $plaintext;

    my $encryption = $self->_encryption;
    unless ($encryption) {
        warn "Pay Via FIS PayDirect: storing '$key' in cleartext because Koha's encryption is"
            . " unavailable. Set 'encryption_key' in koha-conf.xml.";
        $self->store_data( { $key => $plaintext } );
        return;
    }

    $self->store_data( { $key => $ENCRYPTION_PREFIX . $encryption->encrypt_hex( encode_utf8($plaintext) ) } );

    return;
}

=head3 _encrypt_stored_credentials

    $self->_encrypt_stored_credentials;

Encrypts any credential still held in cleartext. Safe to call repeatedly, and never dies: an
instance with no encryption key has to keep working on the cleartext credential it already has.

=cut

sub _encrypt_stored_credentials {
    my ($self) = @_;

    foreach my $key (@CREDENTIAL_KEYS) {
        my $stored = $self->retrieve_data($key);
        next unless defined $stored && length $stored;
        next if index( $stored, $ENCRYPTION_PREFIX ) == 0;

        my $encryption = $self->_encryption;
        unless ($encryption) {
            warn "Pay Via FIS PayDirect: cannot encrypt '$key' because Koha's encryption is"
                . " unavailable. Set 'encryption_key' in koha-conf.xml.";
            next;
        }

        $self->store_data( { $key => $ENCRYPTION_PREFIX . $encryption->encrypt_hex( encode_utf8($stored) ) } );
    }

    return 1;
}

=head3 _migrate_sysprefs_to_plugin_data

    $self->_migrate_sysprefs_to_plugin_data;

Moves settings out of the system preferences the payment path used to read. The system
preference wins over anything in plugin_data, because until now it was the only value the
payment path actually used - what the configuration page wrote was never read. Each
preference is removed only once its value is confirmed stored, so an interrupted run cannot
lose a credential. Safe to call repeatedly.

=cut

sub _migrate_sysprefs_to_plugin_data {
    my ($self) = @_;

    foreach my $key (@CONFIG_KEYS) {
        next unless Koha::Config::SysPrefs->find( lc $key );

        my $syspref = C4::Context->preference($key);

        if ( defined $syspref && length $syspref ) {
            $self->store_data( { $key => $syspref } );

            # Only drop the preference once the value is safely in plugin_data
            my $stored = $self->retrieve_data($key);
            next unless defined $stored && $stored eq $syspref;
        }

        C4::Context->delete_preference($key);
    }

    return 1;
}

=head3 upgrade

Moves settings out of system preferences into plugin_data, then encrypts credentials that
earlier versions of this plugin stored in cleartext.

=cut

sub upgrade {
    my ( $self, $args ) = @_;

    $self->_migrate_sysprefs_to_plugin_data;
    $self->_encrypt_stored_credentials;

    return 1;
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
