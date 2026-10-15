import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

/// The certificate a device serves its links with. Self-signed: links carry
/// its fingerprint, and clients trust nothing else. EC P-256, since an RSA
/// key pair takes seconds to generate in Dart on a phone.
final class TlsIdentity {
  const TlsIdentity({
    required this.certificatePem,
    required this.privateKeyPem,
  });

  factory TlsIdentity.generate() {
    final pair = CryptoUtils.generateEcKeyPair();
    final private = pair.privateKey as ECPrivateKey;
    final public = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': 'SillyDraft'},
      private,
      public,
    );
    return TlsIdentity(
      certificatePem: X509Utils.generateSelfSignedCertificate(
        private,
        csr,
        3650,
      ),
      privateKeyPem: CryptoUtils.encodeEcPrivateKeyToPem(private),
    );
  }

  factory TlsIdentity.fromJson(Map<String, dynamic> json) => TlsIdentity(
    certificatePem: json['certificate'] as String,
    privateKeyPem: json['privateKey'] as String,
  );

  final String certificatePem, privateKeyPem;

  Map<String, String> toJson() => {
    'certificate': certificatePem,
    'privateKey': privateKeyPem,
  };

  /// SHA-256 of the certificate's DER bytes, lowercase hex.
  String get fingerprint {
    final body = certificatePem.replaceAll(RegExp(r'-----[^-]+-----|\s'), '');
    return sha256.convert(base64Decode(body)).toString();
  }

  SecurityContext get serverContext => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
}

/// An HTTP client that accepts only the certificate with [fingerprint]. It
/// trusts no system roots, so even a publicly trusted certificate fails.
HttpClient pinnedClient(String fingerprint) =>
    HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = (certificate, _, _) =>
          sha256.convert(certificate.der).toString() == fingerprint;
