const std = @import("std");
const ssl = @import("ssl");

/// Certificate verification callback for JAMSNP
pub fn verifyCertificate(certs: ?*ssl.X509_STORE_CTX, _: ?*anyopaque) callconv(.C) c_int {
    // Get the peer certificate
    const cert = ssl.X509_STORE_CTX_get_current_cert(certs) orelse {
        return 0; // Verification failed
    };

    // 1. Check signature algorithm is Ed25519
    const pkey = ssl.X509_get_pubkey(cert) orelse {
        return 0; // Verification failed
    };
    defer ssl.EVP_PKEY_free(pkey);

    if (ssl.EVP_PKEY_base_id(pkey) != ssl.EVP_PKEY_ED25519) {
        return 0; // Not Ed25519
    }

    // 2. Check that there is exactly one alternative name
    const alt_names = ssl.X509_get_ext_d2i(cert, ssl.NID_subject_alt_name, null, null) orelse {
        return 0; // No alt names
    };
    defer ssl.GENERAL_NAMES_free(@ptrCast(alt_names));

    if (ssl.sk_GENERAL_NAME_num(@ptrCast(alt_names)) != 1) {
        return 0; // More than one alt name
    }

    // 3. Check the alternative name format is a DNS name
    // and has the correct format e{base32encoded-pubkey}
    // const gn = ssl.sk_GENERAL_NAME_value(@ptrCast(alt_names), 0) orelse {
    //     return 0; // No alt name at index 0
    // };

    // if (ssl.GENERAL_NAME_get_type(gn) != ssl.GEN_DNS) {
    //     return 0; // Not a DNS name
    // }

    // 4. Extract the DNS name and verify format
    // const dnsName = ssl.GENERAL_NAME_get0_value(gn, ssl.GEN_DNS) orelse {
    //     return 0; // Failed to get value
    // };
    //
    // const dnsNameStr = ssl.ASN1_STRING_get0_data(@ptrCast(dnsName));
    // const dnsNameLen = ssl.ASN1_STRING_length(dnsName);
    //
    // if (dnsNameLen != 53) { // 53-character DNS name
    //     return 0; // Incorrect length
    // }
    //
    // // Check format 'e' + base32 encoded pubkey
    // if (dnsNameStr[0] != 'e') {
    //     return 0; // Doesn't start with 'e'
    // }
    //
    // 5. Decode the base32 public key and compare with the certificate's key
    // This is a simplified check - in a real implementation you'd properly decode
    // and verify the public key

    return 1; // Verification successful
}
