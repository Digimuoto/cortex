{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Platform.Crypto
-- Description : AES-256-GCM encryption for organization credentials
-- Copyright   : (c) 2026
-- License     : MIT
-- Maintainer  : julius@koskela.email
--
-- Provides encryption/decryption for organization-level API credentials.
--
-- Security design:
-- - AES-256-GCM for authenticated encryption
-- - HKDF-SHA256 for key derivation from admin pepper
-- - Unique 12-byte nonce per encryption
-- - Context-specific key derivation (one key per provider)
--
-- The admin pepper is loaded from systemd LoadCredential at startup.
-- Each provider gets a derived key using HKDF with provider name as info.
module Platform.Crypto
  ( -- * Key derivation
    deriveCredentialKey,
    CredentialKey (..),

    -- * Encryption/Decryption
    encryptCredential,
    decryptCredential,
    EncryptedCredential (..),
    CryptoError (..),

    -- * Nonce generation
    generateNonce,
    Nonce (..),

    -- * Types
    AdminPepper (..),
    Provider (..),
  )
where

import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types
  ( AEAD,
    AEADMode (..),
    AuthTag (..),
    aeadInit,
    aeadSimpleDecrypt,
    aeadSimpleEncrypt,
    cipherInit,
  )
import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (SHA256)
import Crypto.KDF.HKDF (PRK, expand, extract)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import "memory" Data.ByteArray (Bytes, convert)

-- | Admin pepper loaded from systemd credential
newtype AdminPepper = AdminPepper {unAdminPepper :: ByteString}
  deriving (Eq)

-- | No Show instance to prevent accidental logging
instance Show AdminPepper where
  show _ = "AdminPepper <redacted>"

-- | Market data provider identifier for key derivation
newtype Provider = Provider {unProvider :: Text}
  deriving (Eq, Show)

-- | Derived AES-256 key for a specific provider
newtype CredentialKey = CredentialKey {unCredentialKey :: ByteString}
  deriving (Eq)

-- | No Show instance to prevent accidental logging
instance Show CredentialKey where
  show _ = "CredentialKey <redacted>"

-- | 12-byte nonce for AES-GCM
newtype Nonce = Nonce {unNonce :: ByteString}
  deriving (Eq, Show)

-- | Encrypted credential with nonce
data EncryptedCredential = EncryptedCredential
  { -- | AES-GCM ciphertext including 16-byte auth tag
    ecCiphertext :: !ByteString,
    -- | 12-byte nonce used for encryption
    ecNonce :: !Nonce
  }
  deriving (Eq, Show)

-- | Cryptographic operation errors
data CryptoError
  = InvalidKeyLength !Int
  | InvalidNonceLength !Int
  | CipherInitFailed !String
  | AEADInitFailed !String
  | DecryptionFailed
  | AuthTagMismatch
  deriving (Eq, Show)

-- | HKDF salt for key derivation (fixed, public)
hkdfSalt :: ByteString
hkdfSalt = "portman-org-credentials-v1"

-- |
-- Derive a provider-specific encryption key from admin pepper.
--
-- Uses HKDF-SHA256 with:
-- - IKM: admin pepper
-- - Salt: fixed public salt
-- - Info: provider name (for domain separation)
-- - Output: 32 bytes (AES-256 key)
--
-- Each provider gets a unique derived key, so compromise of one
-- credential doesn't expose others.
deriveCredentialKey :: AdminPepper -> Provider -> CredentialKey
deriveCredentialKey (AdminPepper pepper) (Provider provider) =
  let -- Extract phase: PRK = HKDF-Extract(salt, IKM)
      prk :: PRK SHA256
      prk = extract hkdfSalt pepper
      -- Expand phase: OKM = HKDF-Expand(PRK, info, L)
      info = "credential:" <> TE.encodeUtf8 provider
      okm = expand prk info 32 :: ByteString
   in CredentialKey okm

-- |
-- Generate a cryptographically secure 12-byte nonce.
--
-- IMPORTANT: Each encryption MUST use a unique nonce.
-- With AES-GCM, nonce reuse is catastrophic (reveals key).
generateNonce :: IO Nonce
generateNonce = Nonce <$> getRandomBytes 12

-- |
-- Encrypt an API credential using AES-256-GCM.
--
-- Returns ciphertext with appended 16-byte authentication tag.
-- The nonce must be stored alongside the ciphertext for decryption.
--
-- Example usage:
-- @
-- pepper <- loadAdminPepper
-- let key = deriveCredentialKey pepper (Provider "eodhd")
-- nonce <- generateNonce
-- case encryptCredential key nonce "my-api-key-12345" of
--   Left err -> handleError err
--   Right encrypted -> storeInDatabase encrypted
-- @
encryptCredential ::
  CredentialKey ->
  Nonce ->
  -- | Plaintext API key
  ByteString ->
  Either CryptoError EncryptedCredential
encryptCredential (CredentialKey keyBytes) (Nonce nonceBytes) plaintext
  | BS.length keyBytes /= 32 = Left $ InvalidKeyLength (BS.length keyBytes)
  | BS.length nonceBytes /= 12 = Left $ InvalidNonceLength (BS.length nonceBytes)
  | otherwise = do
      -- Initialize AES-256 cipher
      cipher <- case cipherInit keyBytes :: CryptoFailable AES256 of
        CryptoPassed c -> Right c
        CryptoFailed e -> Left $ CipherInitFailed (show e)

      -- Initialize AEAD with GCM mode
      aead <- case aeadInit AEAD_GCM cipher nonceBytes :: CryptoFailable (AEAD AES256) of
        CryptoPassed a -> Right a
        CryptoFailed e -> Left $ AEADInitFailed (show e)

      -- Encrypt with empty AAD, returns (AuthTag, ciphertext)
      let (AuthTag tagBytes, ciphertext) = aeadSimpleEncrypt aead BS.empty plaintext 16

      -- Append auth tag to ciphertext (standard format)
      let ciphertextWithTag = ciphertext <> convert tagBytes

      Right $ EncryptedCredential ciphertextWithTag (Nonce nonceBytes)

-- |
-- Decrypt an API credential using AES-256-GCM.
--
-- Verifies the authentication tag and returns plaintext on success.
-- Returns DecryptionFailed if the tag doesn't match (tampering detected).
--
-- Example usage:
-- @
-- pepper <- loadAdminPepper
-- let key = deriveCredentialKey pepper (Provider "eodhd")
-- case decryptCredential key encrypted of
--   Left err -> handleError err
--   Right plaintext -> useApiKey plaintext
-- @
decryptCredential ::
  CredentialKey ->
  EncryptedCredential ->
  Either CryptoError ByteString
decryptCredential (CredentialKey keyBytes) (EncryptedCredential ciphertextWithTag (Nonce nonceBytes))
  | BS.length keyBytes /= 32 = Left $ InvalidKeyLength (BS.length keyBytes)
  | BS.length nonceBytes /= 12 = Left $ InvalidNonceLength (BS.length nonceBytes)
  | BS.length ciphertextWithTag < 16 = Left DecryptionFailed -- Must have at least auth tag
  | otherwise = do
      -- Split ciphertext and auth tag
      let tagSize = 16
          ciphertextLen = BS.length ciphertextWithTag - tagSize
          ciphertext = BS.take ciphertextLen ciphertextWithTag
          tagBytes = BS.drop ciphertextLen ciphertextWithTag

      -- Initialize AES-256 cipher
      cipher <- case cipherInit keyBytes :: CryptoFailable AES256 of
        CryptoPassed c -> Right c
        CryptoFailed e -> Left $ CipherInitFailed (show e)

      -- Initialize AEAD with GCM mode
      aead <- case aeadInit AEAD_GCM cipher nonceBytes :: CryptoFailable (AEAD AES256) of
        CryptoPassed a -> Right a
        CryptoFailed e -> Left $ AEADInitFailed (show e)

      -- Decrypt with verification
      let authTag = AuthTag (convert tagBytes :: Bytes)
      case aeadSimpleDecrypt aead BS.empty ciphertext authTag of
        Nothing -> Left AuthTagMismatch
        Just plaintext -> Right plaintext
