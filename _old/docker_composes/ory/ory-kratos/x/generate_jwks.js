#!/usr/bin/env node

/**
 * Generate jwks.json for Ory Kratos
 * Usage: node generate-jwks.js
 */

const crypto = require('crypto');
const fs = require('fs');

function generateKid() {
  return crypto.randomBytes(16).toString('hex');
}

function generateJWKS() {
  console.log('🔐 Generating RS256 JWKS for Ory Kratos...\n');

  // Generate 2048-bit RSA key pair
  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: {
      type: 'spki',
      format: 'jwk'
    },
    privateKeyEncoding: {
      type: 'pkcs8',
      format: 'jwk'
    }
  });

  const kid = generateKid();

  // Public JWK for JWKS
  const publicJWK = {
    use: 'sig',
    kty: publicKey.kty,
    kid: kid,
    alg: 'RS256',
    n: publicKey.n,
    e: publicKey.e
  };

  // Private JWK (full key with private components)
  const privateJWK = {
    use: 'sig',
    kty: privateKey.kty,
    kid: kid,
    alg: 'RS256',
    n: privateKey.n,
    e: privateKey.e,
    d: privateKey.d,
    p: privateKey.p,
    q: privateKey.q,
    dp: privateKey.dp,
    dq: privateKey.dq,
    qi: privateKey.qi
  };

  // JWKS format with private key (Kratos needs the private key to sign)
  const jwks = {
    keys: [privateJWK]
  };

  // Save to file
  fs.writeFileSync('jwks.json', JSON.stringify(jwks, null, 2));

  console.log('✅ Generated jwks.json successfully!\n');
  console.log('📄 File contents:');
  console.log('=' .repeat(70));
  console.log(JSON.stringify(jwks, null, 2));
  console.log('=' .repeat(70));
  console.log(`\n🔑 Key ID (kid): ${kid}`);
  console.log('\n⚠️  SECURITY: This file contains the PRIVATE key.');
  console.log('   Mount it securely to Kratos and keep it secret!\n');
}

generateJWKS();
