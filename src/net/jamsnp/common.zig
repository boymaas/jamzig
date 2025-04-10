const std = @import("std");
const ssl = @import("ssl");
const constants = @import("constants.zig");

/// Builds the ALPN identifier string for JAMSNP
pub fn buildAlpnIdentifier(allocator: std.mem.Allocator, chain_genesis_hash: []const u8, is_builder: bool) ![:0]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 64);
    const writer = buffer.writer();

    // Format: jamnp-s/0/abcdef12 or jamnp-s/0/abcdef12/builder
    try writer.print("{s}/{s}/{s}", .{
        constants.PROTOCOL_PREFIX,
        constants.PROTOCOL_VERSION,
        chain_genesis_hash[0..8],
    });

    if (is_builder) {
        try writer.writeAll("/builder");
    }

    return try buffer.toOwnedSliceSentinel(0);
}

pub const X509Certificate = struct {
    // FIXME: remove panics
    fn create(keypair: std.crypto.sign.Ed25519.KeyPair) *ssl.X509 {
        const pkey = ssl.EVP_PKEY_new_raw_private_key(ssl.EVP_PKEY_ED25519, null, &keypair.secret_key.bytes, 32) orelse {
            @panic("EVP_PKEY_set_raw_private_key failed");
        };

        const cert = ssl.X509_new() orelse {
            @panic("X509_new failed");
        };

        if (ssl.X509_set_version(cert, ssl.X509_VERSION_3) == 0) {
            @panic("EVP_PKEY_keygen failed");
        }

        const serial = ssl.ASN1_INTEGER_new() orelse {
            @panic("ASN1_INTEGER_new failed");
        };
        defer ssl.ASN1_INTEGER_free(serial);
        if (ssl.ASN1_INTEGER_set(serial, 1) == 0) {
            @panic("ASN1_INTEGER_set failed");
        }
        if (ssl.X509_set_serialNumber(cert, serial) == 0) {
            @panic("X509_set_serialNumber failed");
        }

        const issuer = ssl.X509_get_issuer_name(cert) orelse {
            @panic("X509_get_issuer_name failed");
        };
        if (ssl.X509_NAME_add_entry_by_txt(
            issuer,
            "CN",
            ssl.MBSTRING_ASC,
            "JamZig Node",
            -1,
            -1,
            0,
        ) == 0) {
            @panic("X509_NAME_add_entry_by_txt failed");
        }

        if (ssl.X509_gmtime_adj(ssl.X509_get_notBefore(cert), 0) == null) {
            @panic("X509_gmtime_adj failed");
        }
        // I sure hope 1000 years is enough :P
        if (ssl.X509_gmtime_adj(ssl.X509_get_notAfter(cert), 60 * 60 * 24 * 365 * 1000) == null) {
            @panic("X509_gmtime_adj failed");
        }

        if (ssl.X509_set_subject_name(cert, issuer) == 0) {
            @panic("X509_set_subject_name failed");
        }

        if (ssl.X509_set_pubkey(cert, pkey) == 0) {
            @panic("X509_set_pubkey failed");
        }

        if (ssl.X509_sign(cert, pkey, null) == 0) {
            @panic("X509_sign failed");
        }

        return cert;
    }
};

/// Configure SSL context for JAMSNP
pub fn configureSSLContext(
    allocator: std.mem.Allocator,
    keypair: std.crypto.sign.Ed25519.KeyPair,
    chain_genesis_hash: []const u8,
    is_client: bool,
    is_builder: bool,
) !*ssl.SSL_CTX {
    const ssl_ctx = ssl.SSL_CTX_new(ssl.TLS_method()) orelse
        return error.SSLContextCreationFailed;
    errdefer ssl.SSL_CTX_free(ssl_ctx);

    ssl.SSL_CTX_set_info_callback(ssl_ctx, ssl_info_callback); // Register the callback

    // Set TLS 1.3 protocol
    if (ssl.SSL_CTX_set_min_proto_version(ssl_ctx, ssl.TLS1_3_VERSION) == 0)
        return error.SSLConfigurationFailed;
    if (ssl.SSL_CTX_set_max_proto_version(ssl_ctx, ssl.TLS1_3_VERSION) == 0)
        return error.SSLConfigurationFailed;

    // Configure Ed25519 signature algorithm
    const signature_algs = [_]u16{ssl.SSL_SIGN_ED25519};
    if (ssl.SSL_CTX_set_verify_algorithm_prefs(ssl_ctx, &signature_algs, 1) == 0)
        return error.SSLConfigurationFailed;

    // Create certificate with the required format
    const cert = X509Certificate.create(keypair);
    defer ssl.X509_free(cert);

    // Create EVP_PKEY from the raw private key bytes in the keypair
    const pkey = ssl.EVP_PKEY_new_raw_private_key(
        ssl.EVP_PKEY_ED25519, // Specify the algorithm type
        null, // Engine (usually null)
        &keypair.secret_key.bytes, // Pointer to the raw private key bytes (assuming keypair.private is []const u8)
        32, // Length of the private key (should be 32 for Ed25519)
    ) orelse return error.SSLConfigurationFailed; // Or a more specific error
    defer ssl.EVP_PKEY_free(pkey);

    // Now, load the *correct* private key into the context
    if (ssl.SSL_CTX_use_PrivateKey(ssl_ctx, pkey) == 0) { // Should return 1 on success
        // Handle error - print BoringSSL error stack?
        return error.SSLConfigurationFailed;
    }

    // Load the certificate generated earlier
    if (ssl.SSL_CTX_use_certificate(ssl_ctx, cert) == 0) { // Should return 1 on success
        // Handle error
        return error.SSLConfigurationFailed;
    }

    // It's often good practice to check consistency after loading both:
    if (ssl.SSL_CTX_check_private_key(ssl_ctx) == 0) {
        std.log.err("Private key does not match the certificate public key", .{});
        return error.SSLConfigurationFailed;
    }

    // Set private key and certificate
    if (ssl.SSL_CTX_use_PrivateKey(ssl_ctx, pkey) == 0)
        return error.SSLConfigurationFailed;
    if (ssl.SSL_CTX_use_certificate(ssl_ctx, cert) == 0)
        return error.SSLConfigurationFailed;

    // Set up certificate verification
    if (is_client) {
        // For clients, verify peer certificate
        ssl.SSL_CTX_set_verify(ssl_ctx, ssl.SSL_VERIFY_PEER, null);
    } else {
        // For servers, both request and verify client certificates
        ssl.SSL_CTX_set_verify(ssl_ctx, ssl.SSL_VERIFY_PEER | ssl.SSL_VERIFY_FAIL_IF_NO_PEER_CERT, null);
    }

    // Set ALPN
    // FIXME: check this is a memory leak, just for making this work for now
    const alpn_id = try buildAlpnIdentifier(allocator, chain_genesis_hash, is_builder);
    // defer allocator.free(alpn_id);

    const alpn_protos = [1][]const u8{alpn_id};

    if (is_client) {
        // Client sets the protocols it supports
        var alpn_proto_list: [128]u8 = undefined;
        var total_len: usize = 0;

        for (alpn_protos) |proto| {
            alpn_proto_list[total_len] = @intCast(proto.len);
            @memcpy(alpn_proto_list[total_len + 1 ..][0..proto.len], proto);
            total_len += 1 + proto.len;
        }

        if (ssl.SSL_CTX_set_alpn_protos(ssl_ctx, &alpn_proto_list, @intCast(total_len)) != 0) {
            return error.AlpnConfigurationFailed;
        }
    } else {
        // Server selects from offered protocols
        const select_cb = struct {

            // (SSL *ssl, const unsigned char **out, unsigned char *outlen, const unsigned char *in, unsigned int inlen, void *arg)
            // SSL_CTX_set_alpn_select_cb() sets the application callback cb
            // used by a server to select which protocol to use for the
            // incoming connection. When cb is NULL, ALPN is not used. The arg
            // value is a pointer which is passed to the application callback.
            //
            // cb is the application defined callback. The in, inlen parameters
            // are a vector in protocol-list format. The value of the out,
            // outlen vector should be set to the value of a single protocol
            // selected from the in, inlen vector. The out buffer may point
            // directly into in, or to a buffer that outlives the handshake.
            // The arg parameter is the pointer set via
            // SSL_CTX_set_alpn_select_cb().
            pub fn callback(_: ?*ssl.SSL, out: [*c][*c]const u8, outlen: [*c]u8, in: [*c]const u8, inlen: c_uint, arg: ?*anyopaque) callconv(.C) c_int {
                const supported_proto: [*:0]const u8 = @ptrCast(@alignCast(arg));
                const blah = std.mem.sliceTo(supported_proto, 0);

                std.debug.print("ALPN: {s}", .{supported_proto});

                var i: usize = 0;
                while (i < inlen) {
                    const proto_len = in[i];
                    i += 1;
                    if (i + proto_len > inlen) break;

                    const proto = in[i..][0..proto_len];

                    // Check if the protocol is acceptable
                    if (std.mem.eql(u8, proto[0..proto_len], blah)) {
                        // Out points to the in
                        out.* = @ptrCast(proto.ptr);
                        outlen.* = @intCast(proto.len);
                        return ssl.SSL_TLSEXT_ERR_OK;
                    }

                    i += proto_len;
                }

                return ssl.SSL_TLSEXT_ERR_NOACK;
            }
        }.callback;

        ssl.SSL_CTX_set_alpn_select_cb(ssl_ctx, select_cb, @ptrCast(alpn_id.ptr));
    }

    return ssl_ctx;
}

fn ssl_info_callback(ssl_handle: ?*const ssl.SSL, where_val: c_int, ret: c_int) callconv(.C) void {
    // Get state string only if handle is not null (can be null in early stages)
    const state_str = if (ssl_handle) |handle| ssl.SSL_state_string_long(handle) else @as([*c]const u8, @ptrCast("(null handle)"));

    std.debug.print("\x1b[32mSSL INFO: State='{s}', Where=0x{x} ({s}), Ret={d}\x1b[0m\n", .{
        state_str,
        where_val,
        ssl.SSL_state_string_long(ssl_handle), // You might want more specific where flags decoded here
        ret,
    });

    // Add more detailed logging for alerts
    if ((where_val & ssl.SSL_CB_ALERT) != 0) {
        const is_write = (where_val & ssl.SSL_CB_WRITE) != 0;
        const alert_level_str = ssl.SSL_alert_type_string_long(ret); // Level is in upper byte of ret
        const alert_desc_str = ssl.SSL_alert_desc_string_long(ret); // Desc is in lower byte of ret
        std.debug.print("\x1b[31mSSL ALERT {s}: Level='{s}', Desc='{s}' (ret={d})\x1b[0m\n", .{
            if (is_write) "WRITE" else "READ",
            alert_level_str,
            alert_desc_str,
            ret,
        });
    }
}
