const std = @import("std");

const ssl = @import("ssl");

const constants = @import("constants.zig");

const Base32 = @import("../base32.zig").Encoding;

const trace = @import("tracing").scoped(.network);

/// Builds the ALPN identifier string for JAMSNP
pub fn buildAlpnIdentifier(allocator: std.mem.Allocator, chain_genesis_hash: []const u8, is_builder: bool) ![]u8 {
    const span = trace.span(@src(), .build_alpn_identifier);
    defer span.deinit();
    span.debug("Building ALPN identifier", .{});
    span.trace("Chain genesis hash: {s}, is_builder: {}", .{ std.fmt.fmtSliceHexLower(chain_genesis_hash), is_builder });

    var buffer = try std.ArrayList(u8).initCapacity(allocator, 64);
    const writer = buffer.writer();

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
    const span = trace.span(@src(), .alt_name_generation);
    defer span.deinit();

    result[0] = 'e';
    _ = Base32.encode(result[1 .. Base32.encodeLen(32) + 1], pubkey);

    span.debug("Generated Alt Name: {s}", .{result});
}

pub const X509Certificate = struct {
    /// Create a certificate that conforms to the JAMSNP specification:
    /// - Use Ed25519 as the signature algorithm
    /// - Have a single alternative name: DNS name "e" followed by base32 encoded public key
    /// - Use the peer's Ed25519 key
    fn create(keypair: std.crypto.sign.Ed25519.KeyPair) *ssl.X509 {
        const span = trace.span(@src(), .create_certificate);
        defer span.deinit();
        span.debug("Creating X509 certificate with Ed25519 key", .{});
        span.trace("Public key: {s}", .{std.fmt.fmtSliceHexLower(&keypair.public_key.bytes)});

        const pkey = ssl.EVP_PKEY_new_raw_private_key(ssl.EVP_PKEY_ED25519, null, &keypair.secret_key.bytes, 32) orelse {
            span.err("Failed to create EVP_PKEY from Ed25519 private key", .{});
            @panic("EVP_PKEY_new_raw_private_key failed");
        };
        defer ssl.EVP_PKEY_free(pkey);
        span.trace("Created EVP_PKEY from Ed25519 private key", .{});

        const cert = ssl.X509_new() orelse {
            span.err("Failed to create X509 certificate", .{});
            @panic("X509_new failed");
        };
        span.trace("Created new X509 certificate", .{});

        if (ssl.X509_set_version(cert, ssl.X509_VERSION_3) == 0) {
            span.err("Failed to set X509 version", .{});
            @panic("X509_set_version failed");
        }
        span.trace("Set certificate version to X509v3", .{});

        const serial = ssl.ASN1_INTEGER_new() orelse {
            span.err("Failed to create ASN1 integer for serial number", .{});
            @panic("ASN1_INTEGER_new failed");
        };
        defer ssl.ASN1_INTEGER_free(serial);
        span.trace("Created ASN1 integer for serial number", .{});

        if (ssl.ASN1_INTEGER_set(serial, 1) == 0) {
            span.err("Failed to set serial number value", .{});
            @panic("ASN1_INTEGER_set failed");
        }
        span.trace("Set serial number value to 1", .{});

        if (ssl.X509_set_serialNumber(cert, serial) == 0) {
            span.err("Failed to set certificate serial number", .{});
            @panic("X509_set_serialNumber failed");
        }
        span.trace("Applied serial number to certificate", .{});

        const issuer = ssl.X509_get_issuer_name(cert) orelse {
            span.err("Failed to get issuer name", .{});
            @panic("X509_get_issuer_name failed");
        };
        span.trace("Got issuer name for self-signed certificate", .{});

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
        span.trace("Added 'JamZig Node' as common name to issuer", .{});

        if (ssl.X509_gmtime_adj(ssl.X509_get_notBefore(cert), 0) == null) {
            span.err("Failed to set notBefore time", .{});
            @panic("X509_gmtime_adj failed");
        }
        span.trace("Set notBefore time to current time", .{});

        if (ssl.X509_gmtime_adj(ssl.X509_get_notAfter(cert), 60 * 60 * 24 * 365 * 1000) == null) {
            span.err("Failed to set notAfter time", .{});
            @panic("X509_gmtime_adj failed");
        }
        span.trace("Set notAfter time to 1000 years in the future", .{});

        if (ssl.X509_set_subject_name(cert, issuer) == 0) {
            span.err("Failed to set subject name", .{});
            @panic("X509_set_subject_name failed");
        }
        span.trace("Set subject name to same as issuer (self-signed)", .{});

        if (ssl.X509_set_pubkey(cert, pkey) == 0) {
            span.err("Failed to set public key", .{});
            @panic("X509_set_pubkey failed");
        }
        span.trace("Set public key in certificate", .{});

        const pubkey = &keypair.public_key.bytes;
        span.trace("Adding SAN with encoded pubkey: {s}", .{std.fmt.fmtSliceHexLower(pubkey)});

        const size = comptime Base32.encodeLen(32) + 1;
        var alt_name: [size]u8 = undefined;

        generateAltName(&alt_name, pubkey);

        var ext_value_buf: [128]u8 = undefined;
        const ext_value = std.fmt.bufPrintZ(&ext_value_buf, "DNS:{s}", .{alt_name}) catch {
            span.err("Failed to format DNS name", .{});
            @panic("bufPrint failed");
        };
        span.trace("Formatted SAN extension value: {s}", .{ext_value});

        const ext = ssl.X509V3_EXT_nconf_nid(
            null, // conf
            null, // ctx
            ssl.NID_subject_alt_name, // ext_nid
            @ptrCast(ext_value.ptr), // value
        ) orelse {
            span.err("Failed to create subject alternative name extension", .{});
            @panic("X509V3_EXT_conf_nid failed");
        };
        span.trace("Created X509 extension for subject alternative names", .{});

        if (ssl.X509_add_ext(cert, ext, -1) == 0) {
            span.err("Failed to add subject alternative name extension to certificate", .{});
            @panic("X509_add_ext failed");
        }
        span.trace("Added subject alternative name extension to certificate", .{});

        ssl.X509_EXTENSION_free(ext);

        if (ssl.X509_sign(cert, pkey, null) == 0) {
            span.err("Failed to sign certificate", .{});
            @panic("X509_sign failed");
        }
        span.trace("Successfully signed certificate with private key", .{});

        span.trace("Certificate creation completed successfully", .{});
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
    const span = trace.span(@src(), .configure_ssl_context);
    defer span.deinit();
    span.debug("Configuring SSL context for JAMSNP", .{});
    span.trace("Parameters - is_client: {}, is_builder: {}, chain_genesis_hash: {s}", .{ is_client, is_builder, std.fmt.fmtSliceHexLower(chain_genesis_hash) });

    const ssl_ctx = ssl.SSL_CTX_new(ssl.TLS_method()) orelse {
        span.err("Failed to create SSL context", .{});
        return error.SSLContextCreationFailed;
    };
    span.trace("Created new SSL context", .{});

    errdefer ssl.SSL_CTX_free(ssl_ctx);


    if (ssl.SSL_CTX_set_min_proto_version(ssl_ctx, ssl.TLS1_3_VERSION) == 0) {
        span.err("Failed to set minimum TLS protocol version to 1.3", .{});
        return error.SSLConfigurationFailed;
    }
    if (ssl.SSL_CTX_set_max_proto_version(ssl_ctx, ssl.TLS1_3_VERSION) == 0) {
        span.err("Failed to set maximum TLS protocol version to 1.3", .{});
        return error.SSLConfigurationFailed;
    }
    span.trace("Set TLS protocol version to 1.3 only", .{});

    const signature_algs = [_]u16{ssl.SSL_SIGN_ED25519};
    if (ssl.SSL_CTX_set_verify_algorithm_prefs(ssl_ctx, &signature_algs, 1) == 0) {
        span.err("Failed to set Ed25519 as signature algorithm", .{});
        return error.SSLConfigurationFailed;
    }
    span.trace("Configured Ed25519 as the signature algorithm", .{});

    const cert_span = span.child(@src(), .create_cert);
    defer cert_span.deinit();
    cert_span.trace("Creating X509 certificate", .{});

    const cert = X509Certificate.create(keypair);
    defer ssl.X509_free(cert);
    cert_span.trace("Created X509 certificate", .{});

    const pkey_span = span.child(@src(), .create_pkey);
    defer pkey_span.deinit();
    pkey_span.trace("Creating EVP_PKEY from Ed25519 private key", .{});

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
    pkey_span.trace("Created EVP_PKEY successfully", .{});

    if (ssl.SSL_CTX_use_PrivateKey(ssl_ctx, pkey) == 0) {
        span.err("Failed to load private key into SSL context", .{});
        return error.SSLConfigurationFailed;
    }
    span.debug("Loaded private key into SSL context", .{});

    if (ssl.SSL_CTX_use_certificate(ssl_ctx, cert) == 0) {
        span.err("Failed to load certificate into SSL context", .{});
        return error.SSLConfigurationFailed;
    }
    span.trace("Loaded certificate into SSL context", .{});

    if (ssl.SSL_CTX_check_private_key(ssl_ctx) == 0) {
        span.err("Private key does not match the certificate public key", .{});
        return error.SSLConfigurationFailed;
    }
    span.trace("Verified private key matches certificate public key", .{});

    const verify_span = span.child(@src(), .cert_verification);
    defer verify_span.deinit();

    if (is_client) {
        verify_span.trace("Configuring certificate verification for client mode", .{});
        ssl.SSL_CTX_set_verify(ssl_ctx, ssl.SSL_VERIFY_PEER, null);
        verify_span.trace("Set client verification to SSL_VERIFY_NONE", .{});
    } else {
        verify_span.trace("Configuring certificate verification for server mode", .{});
        ssl.SSL_CTX_set_verify(ssl_ctx, ssl.SSL_VERIFY_PEER | ssl.SSL_VERIFY_FAIL_IF_NO_PEER_CERT, null);
        verify_span.trace("Set server verification to SSL_VERIFY_NONE | SSL_VERIFY_FAIL_IF_NO_PEER_CERT", .{});
    }

    const alpn_span = span.child(@src(), .configure_alpn);
    defer alpn_span.deinit();

    alpn_span.trace("Using provided ALPN identifier: {s}", .{alpn_id});

    const alpn_protos = [1][]const u8{alpn_id};

    if (is_client) {
        alpn_span.trace("Setting ALPN protocols for client mode", .{});
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
        alpn_span.trace("Setting ALPN select callback for server mode", .{});
        const select_cb = struct {
            pub fn callback(_: ?*ssl.SSL, out: [*c][*c]const u8, outlen: [*c]u8, in: [*c]const u8, inlen: c_uint, arg: ?*anyopaque) callconv(.C) c_int {
                const callback_span = trace.span(@src(), .alpn_select_callback);
                defer callback_span.deinit();

                const supported_proto: [*:0]const u8 = @ptrCast(@alignCast(arg));
                const supported_proto_slice = std.mem.sliceTo(supported_proto, 0);
                callback_span.trace("ALPN select callback invoked", .{});
                callback_span.trace("Supported protocol: {s}", .{supported_proto_slice});
                callback_span.trace("Client offered protocols length: {d} bytes", .{inlen});

                var i: usize = 0;
                while (i < inlen) {
                    const proto_len = in[i];
                    i += 1;
                    if (i + proto_len > inlen) {
                        callback_span.warn("Malformed protocol list, skipping", .{});
                        break;
                    }

                    const proto = in[i..][0..proto_len];
                    callback_span.trace("Examining offered protocol: {s}", .{proto});

                    if (std.mem.eql(u8, proto[0..proto_len], supported_proto_slice)) {
                        callback_span.debug("Found matching protocol: {s}", .{proto});
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
    const span = trace.span(@src(), .ssl_info_callback);
    defer span.deinit();

    const state_str = if (ssl_handle) |handle| ssl.SSL_state_string_long(handle) else @as([*c]const u8, @ptrCast("(null handle)"));
    span.debug("SSL state change", .{});
    span.trace("State='{s}', Where=0x{x}, Ret={d}", .{ state_str, where_val, ret });

    std.debug.print("\x1b[32mSSL INFO: State='{s}', Where=0x{x} ({s}), Ret={d}\x1b[0m\n", .{
        state_str,
        where_val,
        ssl.SSL_state_string_long(ssl_handle), // You might want more specific where flags decoded here
        ret,
    });

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
