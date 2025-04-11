const std = @import("std");
const ssl = @import("ssl");

const Base32 = @import("../base32.zig").Encoding;

const trace = @import("../../tracing.zig").scoped(.network);

/// Certificate verification callback for JAMSNP
pub fn verifyCertificate(certs: ?*ssl.X509_STORE_CTX, _: ?*anyopaque) callconv(.C) c_int {
    const span = trace.span(.verify_certificate);
    defer span.deinit();
    span.debug("Starting certificate verification", .{});

    const ssl_handle = ssl.X509_STORE_CTX_get_ex_data(certs, ssl.SSL_get_ex_data_X509_STORE_CTX_idx());

    // Now you can use ssl_handle to get the peer certificate or perform other operations
    const cert = ssl.SSL_get_peer_certificate(@ptrCast(ssl_handle));

    // // Get the peer certificate
    // const cert = ssl.X509_STORE_CTX_get_current_cert(certs) orelse {
    //     span.err("Failed to get current certificate", .{});
    //     return 0; // Verification failed
    // };
    span.debug("Got peer certificate", .{});

    // 1. Check signature algorithm is Ed25519
    const pkey = ssl.X509_get_pubkey(cert) orelse {
        span.err("Failed to get public key", .{});
        return 0; // Verification failed
    };
    defer ssl.EVP_PKEY_free(pkey);

    const key_type = ssl.EVP_PKEY_base_id(pkey);
    span.debug("Public key type: {d}", .{key_type});

    if (key_type != ssl.EVP_PKEY_ED25519) {
        span.err("Public key is not Ed25519 (type {d})", .{key_type});
        return 0; // Not Ed25519
    }
    span.debug("Verified Ed25519 signature algorithm", .{});

    // 2. Check that there is exactly one alternative name
    const alt_names = ssl.X509_get_ext_d2i(cert, ssl.NID_subject_alt_name, null, null) orelse {
        span.err("Certificate has no alternative names", .{});
        return 0; // No alt names
    };
    defer ssl.GENERAL_NAMES_free(@ptrCast(alt_names));

    const name_count = ssl.sk_GENERAL_NAME_num(@ptrCast(alt_names));
    span.debug("Found {d} alternative name(s)", .{name_count});

    if (name_count != 1) {
        span.err("Expected exactly 1 alternative name, found {d}", .{name_count});
        return 0; // More than one alt name
    }

    // 3. Check the alternative name format is a DNS name
    const gn = ssl.sk_GENERAL_NAME_value(@ptrCast(alt_names), 0) orelse {
        span.err("Failed to get alternative name at index 0", .{});
        return 0; // No alt name at index 0
    };

    const name_check_span = span.child(.check_alt_name);
    defer name_check_span.deinit();

    // 4. Extract the DNS name and verify format
    var type_val: c_int = undefined;
    const dnsName = ssl.GENERAL_NAME_get0_value(gn, &type_val);

    if (dnsName == null or type_val != ssl.GEN_DNS) {
        name_check_span.err("Alternative name is not a DNS name", .{});
        return 0;
    }
    name_check_span.debug("Alternative name is a DNS name", .{});

    const dnsNameStr = ssl.ASN1_STRING_get0_data(@ptrCast(@alignCast(dnsName)));
    const dnsNameLen: usize = @intCast(ssl.ASN1_STRING_length(@ptrCast(@alignCast(dnsName))));

    name_check_span.debug("DNS name length: {d}", .{dnsNameLen});
    name_check_span.debug("DNS name value: {s}", .{dnsNameStr[0..dnsNameLen]});

    if (dnsNameLen != 53) { // 53-character DNS name
        name_check_span.err("DNS name has invalid length: {d} (expected 53)", .{dnsNameLen});
        return 0; // Incorrect length
    }

    // Create a buffer to safely print the DNS name for logging
    var dns_buffer: [53]u8 = undefined;
    @memcpy(dns_buffer[0..dnsNameLen], dnsNameStr[0..dnsNameLen]);
    name_check_span.trace("DNS name: {s}", .{dns_buffer[0..dnsNameLen]});

    // Check format 'e' + base32 encoded pubkey
    if (dnsNameStr[0] != 'e') {
        name_check_span.err("DNS name doesn't start with 'e'", .{});
        return 0; // Doesn't start with 'e'
    }
    name_check_span.debug("DNS name starts with 'e'", .{});

    // 5. Verify that the rest of the DNS name is base32 encoded
    const base32_check_span = span.child(.check_base32);
    defer base32_check_span.deinit();
    base32_check_span.debug("Checking base32 encoding for DNS name", .{});

    var decode_buffer: [32]u8 = undefined;
    if (Base32.decode(&decode_buffer, dnsNameStr[1..53])) |_| {
        base32_check_span.debug("DNS name is properly base32 encoded", .{});

        // Check if the decoded pubkey matches the certificate's key
        const pubkey_check_span = span.child(.check_pubkey_match);
        defer pubkey_check_span.deinit();
        pubkey_check_span.debug("Checking if decoded pubkey matches certificate pubkey", .{});

        // Get raw Ed25519 key data from EVP_PKEY
        var key_data: [32]u8 = undefined;
        var key_len: usize = key_data.len;
        if (ssl.EVP_PKEY_get_raw_public_key(pkey, &key_data, &key_len) != 1) {
            pubkey_check_span.err("Failed to extract raw public key from certificate", .{});
            return 0;
        }

        if (key_len != 32) {
            pubkey_check_span.err("Unexpected Ed25519 public key length: {d} (expected 32)", .{key_len});
            return 0;
        }

        // Compare the decoded DNS name pubkey with the certificate's pubkey
        if (!std.mem.eql(u8, decode_buffer[0..32], key_data[0..32])) {
            pubkey_check_span.err("Public key in DNS name doesn't match certificate's key", .{});
            return 0;
        }

        pubkey_check_span.debug("Public key in DNS name matches certificate's key", .{});
    } else |err| {
        name_check_span.err("DNS name not properly encoded: {any}", .{err});
        return 0;
    }

    // TODO: Decode the base32 public key and compare with the certificate's key
    span.debug("Certificate verification successful", .{});
    return 1; // Verification successful
}
