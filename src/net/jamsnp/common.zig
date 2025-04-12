const std = @import("std");

const ssl = @import("ssl");

const constants = @import("constants.zig");

const Base32 = @import("../base32.zig").Encoding;

const trace = @import("../../tracing.zig").scoped(.network);

/// Builds the ALPN identifier string for JAMSNP
pub fn buildAlpnIdentifier(allocator: std.mem.Allocator, chain_genesis_hash: []const u8, is_builder: bool) ![]u8 {
    const span = trace.span(.build_alpn_identifier);
    defer span.deinit();
    span.debug("Building ALPN identifier", .{});
    span.trace("Chain genesis hash: {s}, is_builder: {}", .{ std.fmt.fmtSliceHexLower(chain_genesis_hash), is_builder });

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

    const result = try buffer.toOwnedSlice();
    span.debug("ALPN identifier created: {s}", .{result});
    return result;
}

/// Generate an alternative name by encoding the public key in base32 with 'e' prefix
/// Returns a newly allocated string that must be freed by the caller
pub fn generateAltName(result: *[Base32.encodeLen(32) + 1]u8, pubkey: []const u8) void {
    const span = trace.span(.alt_name_generation);
    defer span.deinit();

    // Prefix with an e
    result[0] = 'e';
    // Base32 encode the public key
    _ = Base32.encode(result[1 .. Base32.encodeLen(32) + 1], pubkey);

    span.debug("Generated Alt Name: {s}", .{result});
}

pub const X509Certificate = struct {
    /// Create a certificate that conforms to the JAMSNP specification:
    /// - Use Ed25519 as the signature algorithm
    /// - Have a single alternative name: DNS name "e" followed by base32 encoded public key
    /// - Use the peer's Ed25519 key
    fn create(keypair: std.crypto.sign.Ed25519.KeyPair) *ssl.X509 {
        const span = trace.span(.create_certificate);
        defer span.deinit();
        span.debug("Creating X509 certificate with Ed25519 key", .{});
        span.trace("Public key: {s}", .{std.fmt.fmtSliceHexLower(&keypair.public_key.bytes)});

        // Create private key from Ed25519 keypair
        const pkey = ssl.EVP_PKEY_new_raw_private_key(ssl.EVP_PKEY_ED25519, null, &keypair.secret_key.bytes, 32) orelse {
            span.err("Failed to create EVP_PKEY from Ed25519 private key", .{});
            @panic("EVP_PKEY_new_raw_private_key failed");
        };
        defer ssl.EVP_PKEY_free(pkey);
        span.debug("Created EVP_PKEY from Ed25519 private key", .{});

        // Create new X509 certificate
        const cert = ssl.X509_new() orelse {
            span.err("Failed to create X509 certificate", .{});
            @panic("X509_new failed");
        };
        span.debug("Created new X509 certificate", .{});

        // Set version to X509v3
        if (ssl.X509_set_version(cert, ssl.X509_VERSION_3) == 0) {
            span.err("Failed to set X509 version", .{});
            @panic("X509_set_version failed");
        }
        span.debug("Set certificate version to X509v3", .{});

        // Set serial number
        const serial = ssl.ASN1_INTEGER_new() orelse {
            span.err("Failed to create ASN1 integer for serial number", .{});
            @panic("ASN1_INTEGER_new failed");
        };
        defer ssl.ASN1_INTEGER_free(serial);
        span.debug("Created ASN1 integer for serial number", .{});

        if (ssl.ASN1_INTEGER_set(serial, 1) == 0) {
            span.err("Failed to set serial number value", .{});
            @panic("ASN1_INTEGER_set failed");
        }
        span.debug("Set serial number value to 1", .{});

        if (ssl.X509_set_serialNumber(cert, serial) == 0) {
            span.err("Failed to set certificate serial number", .{});
            @panic("X509_set_serialNumber failed");
        }
        span.debug("Applied serial number to certificate", .{});

        // Set issuer (self-signed)
        const issuer = ssl.X509_get_issuer_name(cert) orelse {
            span.err("Failed to get issuer name", .{});
            @panic("X509_get_issuer_name failed");
        };
        span.debug("Got issuer name for self-signed certificate", .{});

        if (ssl.X509_NAME_add_entry_by_txt(
            issuer,
            "CN",
            ssl.MBSTRING_ASC,
            "JamZig ⚡ Node",
            -1,
            -1,
            0,
        ) == 0) {
            span.err("Failed to add issuer common name", .{});
            @panic("X509_NAME_add_entry_by_txt failed");
        }
        span.debug("Added 'JamZig Node' as common name to issuer", .{});

        // Set validity period
        if (ssl.X509_gmtime_adj(ssl.X509_get_notBefore(cert), 0) == null) {
            span.err("Failed to set notBefore time", .{});
            @panic("X509_gmtime_adj failed");
        }
        span.debug("Set notBefore time to current time", .{});

        // 1000 years validity
        if (ssl.X509_gmtime_adj(ssl.X509_get_notAfter(cert), 60 * 60 * 24 * 365 * 1000) == null) {
            span.err("Failed to set notAfter time", .{});
            @panic("X509_gmtime_adj failed");
        }
        span.debug("Set notAfter time to 1000 years in the future", .{});

        // Set subject name (same as issuer for self-signed)
        if (ssl.X509_set_subject_name(cert, issuer) == 0) {
            span.err("Failed to set subject name", .{});
            @panic("X509_set_subject_name failed");
        }
        span.debug("Set subject name to same as issuer (self-signed)", .{});

        // Set public key
        if (ssl.X509_set_pubkey(cert, pkey) == 0) {
            span.err("Failed to set public key", .{});
            @panic("X509_set_pubkey failed");
        }
        span.debug("Set public key in certificate", .{});

        // Add the required alternative name: 'e' + base32 encoded pubkey
        const pubkey = &keypair.public_key.bytes;
        span.trace("Adding SAN with encoded pubkey: {s}", .{std.fmt.fmtSliceHexLower(pubkey)});

        // Generate the base32 encoded public key
        const size = comptime Base32.encodeLen(32) + 1;
        var alt_name: [size]u8 = undefined;

        // Base32 encode the public key (32 bytes) - results in 52 chars
        generateAltName(&alt_name, pubkey);

        // Create a string for the extension value in OpenSSL format
        // The format is DNS:name
        var ext_value_buf: [128]u8 = undefined;
        const ext_value = std.fmt.bufPrintZ(&ext_value_buf, "DNS:{s}", .{alt_name}) catch {
            span.err("Failed to format DNS name", .{});
            @panic("bufPrint failed");
        };
        span.debug("Formatted SAN extension value: {s}", .{ext_value});

        // Create extension using string format
        const ext = ssl.X509V3_EXT_nconf_nid(
            null, // conf
            null, // ctx
            ssl.NID_subject_alt_name, // ext_nid
            @ptrCast(ext_value.ptr), // value
        ) orelse {
            span.err("Failed to create subject alternative name extension", .{});
            @panic("X509V3_EXT_conf_nid failed");
        };
        span.debug("Created X509 extension for subject alternative names", .{});

        // Add the extension to the certificate
        if (ssl.X509_add_ext(cert, ext, -1) == 0) {
            span.err("Failed to add subject alternative name extension to certificate", .{});
            @panic("X509_add_ext failed");
        }
        span.debug("Added subject alternative name extension to certificate", .{});

        // Free the extension now that it's been added
        ssl.X509_EXTENSION_free(ext);

        // Sign the certificate with our private key
        if (ssl.X509_sign(cert, pkey, null) == 0) {
            span.err("Failed to sign certificate", .{});
            @panic("X509_sign failed");
        }
        span.debug("Successfully signed certificate with private key", .{});

        span.debug("Certificate creation completed successfully", .{});
        return cert;
    }
};

/// Configure SSL context for JAMSNP
pub fn configureSSLContext(
    _: std.mem.Allocator,
    keypair: std.crypto.sign.Ed25519.KeyPair,
    chain_genesis_hash: []const u8,
    is_client: bool,
    is_builder: bool,
    alpn_id: []const u8,
) !*ssl.SSL_CTX {
    const span = trace.span(.configure_ssl_context);
    defer span.deinit();
    span.debug("Configuring SSL context for JAMSNP", .{});
    span.trace("Parameters - is_client: {}, is_builder: {}, chain_genesis_hash: {s}", .{ is_client, is_builder, std.fmt.fmtSliceHexLower(chain_genesis_hash) });

    const ssl_ctx = ssl.SSL_CTX_new(ssl.TLS_method()) orelse {
        span.err("Failed to create SSL context", .{});
        return error.SSLContextCreationFailed;
    };
    span.debug("Created new SSL context", .{});

    errdefer {
        span.debug("Cleaning up SSL context due to error", .{});
        ssl.SSL_CTX_free(ssl_ctx);
    }

    ssl.SSL_CTX_set_info_callback(ssl_ctx, ssl_info_callback); // Register the callback
    span.debug("Registered SSL info callback", .{});

    // Set TLS 1.3 protocol
    if (ssl.SSL_CTX_set_min_proto_version(ssl_ctx, ssl.TLS1_3_VERSION) == 0) {
        span.err("Failed to set minimum TLS protocol version to 1.3", .{});
        return error.SSLConfigurationFailed;
    }
    if (ssl.SSL_CTX_set_max_proto_version(ssl_ctx, ssl.TLS1_3_VERSION) == 0) {
        span.err("Failed to set maximum TLS protocol version to 1.3", .{});
        return error.SSLConfigurationFailed;
    }
    span.debug("Set TLS protocol version to 1.3 only", .{});

    // Configure Ed25519 signature algorithm
    const signature_algs = [_]u16{ssl.SSL_SIGN_ED25519};
    if (ssl.SSL_CTX_set_verify_algorithm_prefs(ssl_ctx, &signature_algs, 1) == 0) {
        span.err("Failed to set Ed25519 as signature algorithm", .{});
        return error.SSLConfigurationFailed;
    }
    span.debug("Configured Ed25519 as the signature algorithm", .{});

    // Create certificate with the required format
    const cert_span = span.child(.create_cert);
    defer cert_span.deinit();
    cert_span.debug("Creating X509 certificate", .{});

    const cert = X509Certificate.create(keypair);
    defer ssl.X509_free(cert);
    cert_span.debug("Created X509 certificate", .{});

    // Create EVP_PKEY from the raw private key bytes in the keypair
    const pkey_span = span.child(.create_pkey);
    defer pkey_span.deinit();
    pkey_span.debug("Creating EVP_PKEY from Ed25519 private key", .{});

    const pkey = ssl.EVP_PKEY_new_raw_private_key(
        ssl.EVP_PKEY_ED25519, // Specify the algorithm type
        null, // Engine (usually null)
        &keypair.secret_key.bytes, // Pointer to the raw private key bytes
        32, // Length of the private key (32 bytes for Ed25519)
    ) orelse {
        pkey_span.err("Failed to create EVP_PKEY from Ed25519 private key", .{});
        return error.SSLConfigurationFailed;
    };
    defer ssl.EVP_PKEY_free(pkey);
    pkey_span.debug("Created EVP_PKEY successfully", .{});

    // Now, load the private key into the context
    if (ssl.SSL_CTX_use_PrivateKey(ssl_ctx, pkey) == 0) {
        span.err("Failed to load private key into SSL context", .{});
        return error.SSLConfigurationFailed;
    }
    span.debug("Loaded private key into SSL context", .{});

    // Load the certificate generated earlier
    if (ssl.SSL_CTX_use_certificate(ssl_ctx, cert) == 0) {
        span.err("Failed to load certificate into SSL context", .{});
        return error.SSLConfigurationFailed;
    }
    span.debug("Loaded certificate into SSL context", .{});

    // Check consistency between private key and certificate
    if (ssl.SSL_CTX_check_private_key(ssl_ctx) == 0) {
        span.err("Private key does not match the certificate public key", .{});
        return error.SSLConfigurationFailed;
    }
    span.debug("Verified private key matches certificate public key", .{});

    // Set certificate verification
    const verify_span = span.child(.cert_verification);
    defer verify_span.deinit();

    if (is_client) {
        verify_span.debug("Configuring certificate verification for client mode", .{});
        // For clients, verify peer certificate
        ssl.SSL_CTX_set_verify(ssl_ctx, ssl.SSL_VERIFY_PEER, null);
        verify_span.debug("Set client verification to SSL_VERIFY_NONE", .{});
    } else {
        verify_span.debug("Configuring certificate verification for server mode", .{});
        // For servers, both request and verify client certificates
        ssl.SSL_CTX_set_verify(ssl_ctx, ssl.SSL_VERIFY_PEER | ssl.SSL_VERIFY_FAIL_IF_NO_PEER_CERT, null);
        verify_span.debug("Set server verification to SSL_VERIFY_NONE | SSL_VERIFY_FAIL_IF_NO_PEER_CERT", .{});
    }

    // Set ALPN
    const alpn_span = span.child(.configure_alpn);
    defer alpn_span.deinit();
    alpn_span.debug("Configuring ALPN", .{});

    alpn_span.debug("Using provided ALPN identifier: {s}", .{alpn_id});

    const alpn_protos = [1][]const u8{alpn_id};

    if (is_client) {
        alpn_span.debug("Setting ALPN protocols for client mode", .{});
        // Client sets the protocols it supports
        var alpn_proto_list: [128]u8 = undefined;
        var total_len: usize = 0;

        for (alpn_protos) |proto| {
            alpn_proto_list[total_len] = @intCast(proto.len);
            @memcpy(alpn_proto_list[total_len + 1 ..][0..proto.len], proto);
            total_len += 1 + proto.len;
        }
        alpn_span.trace("ALPN protocol list - total length: {d} bytes", .{total_len});

        if (ssl.SSL_CTX_set_alpn_protos(ssl_ctx, &alpn_proto_list, @intCast(total_len)) != 0) {
            alpn_span.err("Failed to set ALPN protocols", .{});
            return error.AlpnConfigurationFailed;
        }
        alpn_span.debug("Set client ALPN protocols successfully", .{});
    } else {
        alpn_span.debug("Setting ALPN select callback for server mode", .{});
        // Server selects from offered protocols
        const select_cb = struct {
            pub fn callback(_: ?*ssl.SSL, out: [*c][*c]const u8, outlen: [*c]u8, in: [*c]const u8, inlen: c_uint, arg: ?*anyopaque) callconv(.C) c_int {
                const callback_span = trace.span(.alpn_select_callback);
                defer callback_span.deinit();

                const supported_proto: [*:0]const u8 = @ptrCast(@alignCast(arg));
                const supported_proto_slice = std.mem.sliceTo(supported_proto, 0);
                callback_span.debug("ALPN select callback invoked", .{});
                callback_span.trace("Supported protocol: {s}", .{supported_proto_slice});
                callback_span.trace("Client offered protocols length: {d} bytes", .{inlen});

                var i: usize = 0;
                while (i < inlen) {
                    const proto_len = in[i];
                    i += 1;
                    if (i + proto_len > inlen) {
                        callback_span.debug("Malformed protocol list, skipping", .{});
                        break;
                    }

                    const proto = in[i..][0..proto_len];
                    callback_span.trace("Examining offered protocol: {s}", .{proto});

                    // Check if the protocol is acceptable
                    if (std.mem.eql(u8, proto[0..proto_len], supported_proto_slice)) {
                        callback_span.debug("Found matching protocol: {s}", .{proto});
                        // Out points to the in
                        out.* = @ptrCast(proto.ptr);
                        outlen.* = @intCast(proto.len);
                        return ssl.SSL_TLSEXT_ERR_OK;
                    }

                    i += proto_len;
                }

                callback_span.debug("No matching protocol found", .{});
                return ssl.SSL_TLSEXT_ERR_NOACK;
            }
        }.callback;

        ssl.SSL_CTX_set_alpn_select_cb(ssl_ctx, select_cb, @ptrCast(@constCast(alpn_id.ptr)));
        alpn_span.debug("Set server ALPN select callback successfully", .{});
    }

    span.debug("SSL context configuration completed successfully", .{});
    return ssl_ctx;
}

fn ssl_info_callback(ssl_handle: ?*const ssl.SSL, where_val: c_int, ret: c_int) callconv(.C) void {
    const span = trace.span(.ssl_info_callback);
    defer span.deinit();

    // Get state string only if handle is not null (can be null in early stages)
    const state_str = if (ssl_handle) |handle| ssl.SSL_state_string_long(handle) else @as([*c]const u8, @ptrCast("(null handle)"));
    span.debug("SSL state change", .{});
    span.trace("State='{s}', Where=0x{x}, Ret={d}", .{ state_str, where_val, ret });

    // Also output to standard debug log for visibility during development
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

        span.debug("SSL alert {s}", .{if (is_write) "sent" else "received"});
        span.trace("Alert level: {s}, description: {s}, ret={d}", .{
            alert_level_str,
            alert_desc_str,
            ret,
        });

        std.debug.print("\x1b[31mSSL ALERT {s}: Level='{s}', Desc='{s}' (ret={d})\x1b[0m\n", .{
            if (is_write) "WRITE" else "READ",
            alert_level_str,
            alert_desc_str,
            ret,
        });
    }
}
