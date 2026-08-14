#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More tests => 12;
use Test::Exception;

use C4::Context;
use Koha::Database;

use t::lib::Mocks;

use Koha::Plugin::Com::ByWaterSolutions::PayViaFIS;

my $schema = Koha::Database->new->schema;

my $PREFIX = $Koha::Plugin::Com::ByWaterSolutions::PayViaFIS::ENCRYPTION_PREFIX;

t::lib::Mocks::mock_config( 'encryption_key', 'a test encryption passphrase' );

my $plugin = Koha::Plugin::Com::ByWaterSolutions::PayViaFIS->new( { enable_plugins => 1 } );

# Every subtest calls upgrade() directly. It can't be triggered the normal way here because
# $VERSION is the literal string '{VERSION}' until the kpz is built, so Koha's version
# comparison in Koha::Plugins::Base always decides this is a downgrade and skips the hook.

sub _set_syspref {
    my ( $variable, $value ) = @_;
    C4::Context->set_preference( $variable, $value );
}

sub _syspref_row_exists {
    my ($variable) = @_;
    return Koha::Config::SysPrefs->find( lc $variable ) ? 1 : 0;
}

subtest 'upgrade() moves the API password out of system preferences and encrypts it' => sub {
    plan tests => 4;
    $schema->storage->txn_begin;

    _set_syspref( 'FisApiPassword', 'syspref-password' );
    $plugin->store_data( { FisApiPassword => undef } );

    is( $plugin->upgrade, 1, 'upgrade() returns 1' );

    like( $plugin->retrieve_data('FisApiPassword'), qr/^\Q$PREFIX\E/, 'the password is now in plugin_data, encrypted' );
    is( $plugin->_get_secret('FisApiPassword'), 'syspref-password', 'and decrypts to the original' );
    is( _syspref_row_exists('FisApiPassword'), 0, 'the system preference has been removed' );

    $schema->storage->txn_rollback;
};

subtest 'the system preference wins over an unused plugin_data value' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    # Until now the configuration page wrote to plugin_data while the payment path read the
    # system preference, so only the preference reflects what FIS was actually being sent
    _set_syspref( 'FisApiPassword', 'the-working-password' );
    $plugin->store_data( { FisApiPassword => 'never-used-by-the-payment-path' } );

    $plugin->upgrade;

    is( $plugin->_get_secret('FisApiPassword'), 'the-working-password', 'the working credential survives' );
    is( _syspref_row_exists('FisApiPassword'), 0, 'the system preference has been removed' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade() migrates all five settings' => sub {
    plan tests => 6;
    $schema->storage->txn_begin;

    my %values = (
        FisPostUrl      => 'https://example.com/post',
        FisMerchantCode => 'MERCHANT-1',
        FisSettleCode   => 'SETTLE-1',
        FisApiUrl       => 'https://example.com/api',
        FisApiPassword  => 'syspref-password',
    );
    _set_syspref( $_, $values{$_} ) for keys %values;
    $plugin->store_data( { map { $_ => undef } keys %values } );

    $plugin->upgrade;

    is( $plugin->retrieve_data('FisPostUrl'),      $values{FisPostUrl},      'FisPostUrl migrated' );
    is( $plugin->retrieve_data('FisMerchantCode'), $values{FisMerchantCode}, 'FisMerchantCode migrated' );
    is( $plugin->retrieve_data('FisSettleCode'),   $values{FisSettleCode},   'FisSettleCode migrated' );
    is( $plugin->retrieve_data('FisApiUrl'),       $values{FisApiUrl},       'FisApiUrl migrated' );
    is( $plugin->_get_secret('FisApiPassword'),    $values{FisApiPassword},  'FisApiPassword migrated' );

    my @left = grep { _syspref_row_exists($_) } keys %values;
    is( scalar @left, 0, 'no FIS system preferences are left behind' );

    $schema->storage->txn_rollback;
};

subtest 'only the password is encrypted' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    _set_syspref( 'FisMerchantCode', 'MERCHANT-1' );
    _set_syspref( 'FisApiPassword',  'syspref-password' );
    $plugin->upgrade;

    unlike( $plugin->retrieve_data('FisMerchantCode'), qr/^\Q$PREFIX\E/, 'the merchant code is stored as-is' );
    like( $plugin->retrieve_data('FisApiPassword'), qr/^\Q$PREFIX\E/, 'the password is encrypted' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade() is idempotent' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    _set_syspref( 'FisApiPassword', 'syspref-password' );
    $plugin->upgrade;
    my $after_first = $plugin->retrieve_data('FisApiPassword');

    is( $plugin->upgrade, 1, 'a second upgrade() returns 1' );
    is( $plugin->retrieve_data('FisApiPassword'), $after_first, 'the stored value is byte-identical, so it was not re-encrypted' );
    is( $plugin->_get_secret('FisApiPassword'), 'syspref-password', 'the credential still decrypts to the original' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade() with no system preferences at all' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    $plugin->store_data( { FisApiPassword => 'already-in-plugin-data' } );

    is( $plugin->upgrade, 1, 'upgrade() returns 1' );
    is( $plugin->_get_secret('FisApiPassword'), 'already-in-plugin-data',
        'a value that was already in plugin_data is encrypted in place' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade() is a no-op without an encryption key' => sub {
    plan tests => 4;
    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'encryption_key', q{} );
    _set_syspref( 'FisApiPassword', 'syspref-password' );

    my $returned;
    lives_ok { $returned = $plugin->upgrade } 'upgrade() does not die, so the plugin cannot vanish from the plugin list';
    is( $returned, 1, 'upgrade() still returns 1' );
    is( $plugin->retrieve_data('FisApiPassword'), 'syspref-password', 'the password moved but stayed cleartext' );
    is( _syspref_row_exists('FisApiPassword'), 0, 'the system preference was still removed' );

    t::lib::Mocks::mock_config( 'encryption_key', 'a test encryption passphrase' );

    $schema->storage->txn_rollback;
};

subtest '_set_secret() and _get_secret() round-trip' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    $plugin->_set_secret( 'FisApiPassword', 'a-brand-new-password' );

    my $stored = $plugin->retrieve_data('FisApiPassword');
    like( $stored, qr/^\Q$PREFIX\E/, 'the value was stored with the encryption prefix' );
    unlike( $stored, qr/a-brand-new-password/, 'the cleartext credential does not appear in the stored value' );
    is( $plugin->_get_secret('FisApiPassword'), 'a-brand-new-password', 'the credential round-trips' );

    $schema->storage->txn_rollback;
};

subtest '_get_secret() passes through unencrypted values' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    $plugin->store_data( { FisApiPassword => 'legacy-cleartext' } );
    is( $plugin->_get_secret('FisApiPassword'), 'legacy-cleartext', 'an unprefixed value is returned as-is' );

    $plugin->store_data( { FisApiPassword => undef } );
    is( $plugin->_get_secret('FisApiPassword'), undef, 'a missing credential returns undef rather than dying' );

    $schema->storage->txn_rollback;
};

subtest '_get_secret() fails closed' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    $plugin->store_data( { FisApiPassword => $PREFIX . 'deadbeefdeadbeef' } );
    throws_ok { $plugin->_get_secret('FisApiPassword') } qr/unable to decrypt/,
        'a corrupted credential dies instead of being sent to FIS';

    $plugin->_set_secret( 'FisApiPassword', 'a-brand-new-password' );
    t::lib::Mocks::mock_config( 'encryption_key', q{} );
    throws_ok { $plugin->_get_secret('FisApiPassword') } qr/encryption is unavailable/,
        'an encrypted credential dies when the key is gone';
    t::lib::Mocks::mock_config( 'encryption_key', 'a test encryption passphrase' );

    $schema->storage->txn_rollback;
};

subtest 'debug logging is off unless switched on in the configuration' => sub {
    plan tests => 5;
    $schema->storage->txn_begin;

    # A fresh install, and every install upgrading from a version where debugging was
    # hardcoded on, has no stored value at all
    $plugin->store_data( { EnableDebugging => undef } );
    delete $plugin->{_debugging_enabled};
    is( $plugin->_debugging_enabled, 0, 'off when nothing is stored' );

    $plugin->store_data( { EnableDebugging => 1 } );
    delete $plugin->{_debugging_enabled};
    is( $plugin->_debugging_enabled, 1, 'on when switched on' );

    $plugin->store_data( { EnableDebugging => 0 } );
    delete $plugin->{_debugging_enabled};
    is( $plugin->_debugging_enabled, 0, 'off when switched off' );

    # Cached per object so a request logging a dozen lines makes one query, not a dozen
    $plugin->store_data( { EnableDebugging => 1 } );
    is( $plugin->_debugging_enabled, 0, 'the cached value is reused within one object' );

    delete $plugin->{_debugging_enabled};
    is( $plugin->_debugging_enabled, 1, 'and refreshed on a new object' );

    $schema->storage->txn_rollback;
};

subtest 'a blank credential does not overwrite the stored one' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    $plugin->_set_secret( 'FisApiPassword', 'the-real-password' );
    my $stored = $plugin->retrieve_data('FisApiPassword');

    $plugin->_set_secret( 'FisApiPassword', q{} );
    is( $plugin->retrieve_data('FisApiPassword'), $stored, 'an empty submitted value leaves the stored credential alone' );

    $plugin->_set_secret( 'FisApiPassword', undef );
    is( $plugin->retrieve_data('FisApiPassword'), $stored, 'an absent submitted value leaves the stored credential alone' );

    my $template = $plugin->mbf_read('configure.tt');
    unlike( $template, qr/name="FisApiPassword"[^>]*value="\[%\s*FisApiPassword/,
        'configure.tt never renders the stored credential back into the form field' );

    $schema->storage->txn_rollback;
};
