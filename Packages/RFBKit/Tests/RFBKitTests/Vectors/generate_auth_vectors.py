#!/usr/bin/env python3
"""Generate RFBKit authentication test vectors independently of the Swift implementation.

Regenerate (from Packages/RFBKit):
    python3 Tests/RFBKitTests/Vectors/generate_auth_vectors.py > Tests/RFBKitTests/AuthVectors.swift

Independent tools only:
- big-integer arithmetic: Python's built-in `pow(base, exp, mod)`;
- MD5: `hashlib.md5`;
- DES-ECB and AES-128-ECB: the OpenSSL CLI (tested with OpenSSL 3.6), e.g.
      openssl enc -des-ecb -nopad -K <key hex> -provider legacy -provider default
      openssl enc -aes-128-ecb -nopad -K <key hex>
  OpenSSL's DES is checked first against the FIPS 81 / NBS known-answer vector
  (key 0123456789ABCDEF, "Now is t" -> 3FA40E8A984D4815).
- VNC key bit reversal: done here by reversing each byte's binary string, not with the
  Swift lookup.

All "random" inputs are derived deterministically from SHA-256 of a label, so the output is stable.
"""

import hashlib
import random
import subprocess
import sys

# RFC 2409 §6.2, Oakley group 2 (1024-bit MODP), generator 2.
MODP_1024 = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"
    "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"
    "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF", 16)

# RFC 3526 §3, group 14 (2048-bit MODP), generator 2.
MODP_2048 = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"
    "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"
    "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05"
    "98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"
    "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
    "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"
    "3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF", 16)

# RFC 3526 §5, group 16 (4096-bit MODP). macOS 26 servers send this prime with generator 5.
MODP_4096 = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"
    "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"
    "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05"
    "98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"
    "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
    "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"
    "3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33"
    "A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
    "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864"
    "D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2"
    "08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7"
    "88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8"
    "DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2"
    "233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9"
    "93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF", 16)

# Same rule as AppleDHAuth: the private exponent is drawn from min(key length, 64) random bytes r,
# then x = 2 + (r mod (p - 3)), written on min(key length, len(r) + 1) bytes.
MAX_PRIVATE_KEY_LENGTH = 64


def det(label, n):
    """n deterministic bytes from SHA-256(label || counter)."""
    out = b""
    counter = 0
    while len(out) < n:
        out += hashlib.sha256(f"{label}/{counter}".encode()).digest()
        counter += 1
    return out[:n]


def openssl(cipher, key, data, legacy=False):
    cmd = ["openssl", "enc", cipher, "-nopad", "-K", key.hex()]
    if legacy:
        cmd += ["-provider", "legacy", "-provider", "default"]
    return subprocess.run(cmd, input=data, capture_output=True, check=True).stdout


def bit_reverse(b):
    return int(f"{b:08b}"[::-1], 2)


def to_bytes(value, length):
    return value.to_bytes(length, "big")


def swift_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


# OpenSSL DES self-check against the classic known-answer vector.
assert openssl("-des-ecb", bytes.fromhex("0123456789ABCDEF"), b"Now is t", legacy=True).hex() == "3fa40e8a984d4815"
# AES-128 self-check against FIPS-197 Appendix C.1.
assert openssl("-aes-128-ecb", bytes.fromhex("000102030405060708090a0b0c0d0e0f"),
               bytes.fromhex("00112233445566778899aabbccddeeff")).hex() == "69c4e0d86a7b0430d8cdb78070b4c55a"


def vnc_vectors():
    passwords = ["secret", "", "password", "longerthan8chars", "pässwörd", "1"]
    rows = []
    for index, password in enumerate(passwords):
        raw = password.encode("utf-8")[:8].ljust(8, b"\0")
        key = bytes(bit_reverse(b) for b in raw)
        challenge = det(f"vnc-challenge-{index}", 16)
        response = openssl("-des-ecb", key, challenge, legacy=True)
        rows.append((password, key, challenge, response))
    return rows


def modpow_vectors():
    rng = random.Random(20261019)
    rows = []
    sizes = [8, 16, 63, 64, 65, 127, 128, 129, 256, 512, 521, 1024, 1024, 1536, 2048, 2048, 64, 1024, 2048, 2048]
    for index, bits in enumerate(sizes):
        modulus = rng.getrandbits(bits) | (1 << (bits - 1)) | 1  # odd, exactly `bits` bits
        mod_len = (bits + 7) // 8
        if index == 3:
            exponent = 0                                   # x^0 = 1
        elif index == 4:
            exponent = 1
        else:
            exponent = rng.getrandbits(bits)
        if index in (5, 9, 13):
            base = modulus + rng.getrandbits(bits)         # base >= modulus
        elif index == 6:
            base = 0
        elif index == 7:
            base = modulus - 1
        else:
            base = rng.getrandbits(bits) >> 9              # leading zero bytes when padded
        base_len = max(1, (base.bit_length() + 7) // 8) + (2 if index % 3 == 0 else 0)
        exp_len = max(1, (exponent.bit_length() + 7) // 8) + (1 if index % 4 == 0 else 0)
        result = pow(base, exponent, modulus)
        rows.append((to_bytes(base, base_len), to_bytes(exponent, exp_len), to_bytes(modulus, mod_len),
                     to_bytes(result, mod_len)))
    return rows


def dh_vector(name, generator, prime, key_len, username, password, label, condition=None):
    server_private = int.from_bytes(det(f"{label}-server", key_len), "big") % (prime - 3) + 2
    server_public = pow(generator, server_private, prime)
    attempt = 0
    while True:
        private_key = det(f"{label}-client-{attempt}", min(key_len, MAX_PRIVATE_KEY_LENGTH))
        x = 2 + int.from_bytes(private_key, "big") % (prime - 3)
        assert 2 <= x <= prime - 2
        exponent = to_bytes(x, min(key_len, len(private_key) + 1))
        client_public = to_bytes(pow(generator, x, prime), key_len)
        shared = to_bytes(pow(server_public, x, prime), key_len)
        if condition is None or condition(client_public, shared):
            break
        attempt += 1
    # Both sides agree on the secret.
    assert shared == to_bytes(pow(int.from_bytes(client_public, "big"), server_private, prime), key_len)
    aes_key = hashlib.md5(shared).digest()
    padding = det(f"{label}-padding", 128)
    user, pw = username.encode("utf-8"), password.encode("utf-8")
    assert len(user) <= 63 and len(pw) <= 63
    block = bytearray(padding)
    block[0:len(user)] = user
    block[len(user)] = 0
    block[64:64 + len(pw)] = pw
    block[64 + len(pw)] = 0
    ciphertext = openssl("-aes-128-ecb", aes_key, bytes(block))
    assert len(ciphertext) == 128
    return dict(name=name, generator=generator, prime=to_bytes(prime, key_len),
                server_public=to_bytes(server_public, key_len), private_key=private_key, exponent=exponent,
                padding=padding,
                username=username, password=password, client_public=client_public, shared=shared,
                aes_key=aes_key, plaintext=bytes(block), ciphertext=ciphertext)


def dh_vectors():
    small_prime = 65521  # largest 16-bit prime
    return [
        dh_vector("small prime, shared secret needs left padding", 3, small_prime, 2,
                  "vincent", "s3cret", "dh-small", lambda pub, shared: shared[0] == 0),
        dh_vector("1024-bit MODP group 2", 2, MODP_1024, 128,
                  "vincent", "s3cret pässwörd", "dh-1024"),
        dh_vector("1024-bit, shared secret with a leading zero byte", 2, MODP_1024, 128,
                  "admin", "hunter2", "dh-1024-shared0", lambda pub, shared: shared[0] == 0),
        dh_vector("1024-bit, client public key with a leading zero byte", 2, MODP_1024, 128,
                  "admin", "hunter2", "dh-1024-pub0", lambda pub, shared: pub[0] == 0),
        dh_vector("2048-bit MODP group 14, 63-byte credentials", 2, MODP_2048, 256,
                  "u" * 63, "p" * 63, "dh-2048"),
        dh_vector("4096-bit MODP group 16, generator 5 (macOS 26)", 5, MODP_4096, 512,
                  "vincent", "s3cret", "dh-4096"),
    ]


def main():
    out = sys.stdout
    out.write("// GENERATED by Tests/RFBKitTests/Vectors/generate_auth_vectors.py — do not edit.\n")
    out.write("// Values computed with Python pow/hashlib and the OpenSSL CLI, independently of RFBKit.\n\n")
    out.write("enum AuthVectors {\n")

    out.write("    static let vnc: [VNCVector] = [\n")
    for password, key, challenge, response in vnc_vectors():
        out.write(f"        VNCVector(password: {swift_string(password)}, key: \"{key.hex()}\",\n"
                  f"                  challenge: \"{challenge.hex()}\", response: \"{response.hex()}\"),\n")
    out.write("    ]\n\n")

    out.write("    static let modPow: [ModPowVector] = [\n")
    for base, exponent, modulus, result in modpow_vectors():
        out.write(f"        ModPowVector(base: \"{base.hex()}\",\n"
                  f"                     exponent: \"{exponent.hex()}\",\n"
                  f"                     modulus: \"{modulus.hex()}\",\n"
                  f"                     result: \"{result.hex()}\"),\n")
    out.write("    ]\n\n")

    out.write("    static let appleDH: [AppleDHVector] = [\n")
    for v in dh_vectors():
        out.write(f"        AppleDHVector(\n"
                  f"            name: {swift_string(v['name'])},\n"
                  f"            generator: {v['generator']},\n"
                  f"            prime: \"{v['prime'].hex()}\",\n"
                  f"            serverPublicKey: \"{v['server_public'].hex()}\",\n"
                  f"            privateKey: \"{v['private_key'].hex()}\",\n"
                  f"            exponent: \"{v['exponent'].hex()}\",\n"
                  f"            padding: \"{v['padding'].hex()}\",\n"
                  f"            username: {swift_string(v['username'])},\n"
                  f"            password: {swift_string(v['password'])},\n"
                  f"            clientPublicKey: \"{v['client_public'].hex()}\",\n"
                  f"            sharedSecret: \"{v['shared'].hex()}\",\n"
                  f"            aesKey: \"{v['aes_key'].hex()}\",\n"
                  f"            plaintext: \"{v['plaintext'].hex()}\",\n"
                  f"            ciphertext: \"{v['ciphertext'].hex()}\"),\n")
    out.write("    ]\n")
    out.write("}\n")


if __name__ == "__main__":
    main()
