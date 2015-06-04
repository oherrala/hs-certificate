-- |
-- Module      : Data.X509.PublicKey
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- Public key handling in X.509 infrastructure
--
module Data.X509.PublicKey
    ( PubKey(..)
    , pubkeyToAlg
    ) where

import Data.ASN1.Types
import Data.ASN1.Encoding
import Data.ASN1.BinaryEncoding
import Data.ASN1.BitArray

import Data.Bits

import Data.X509.Internal
import Data.X509.OID
import Data.X509.AlgorithmIdentifier

import qualified Crypto.PubKey.RSA.Types as RSA
import qualified Crypto.PubKey.DSA       as DSA
import qualified Crypto.PubKey.ECC.Types as ECC
import Data.Word

import qualified Data.ByteString as B

-- | Public key types known and used in X.509
data PubKey =
      PubKeyRSA RSA.PublicKey -- ^ RSA public key
    | PubKeyDSA DSA.PublicKey -- ^ DSA public key
    | PubKeyDH (Integer,Integer,Integer,Maybe Integer,([Word8], Integer))
                                -- ^ DH format with (p,g,q,j,(seed,pgenCounter))
    | PubKeyECDSA ECC.CurveName B.ByteString
    | PubKeyUnknown OID B.ByteString -- ^ unrecognized format
    deriving (Show,Eq)

-- Public key are in the format:
--
-- Start Sequence
--      OID (Public key algorithm)
--      [public key specific format]
--      BitString
-- End Sequence
instance ASN1Object PubKey where
    fromASN1 (Start Sequence:Start Sequence:OID pkalg:xs)
        | pkalg == getObjectID PubKeyALG_RSA =
            case removeNull xs of
                End Sequence:BitString bits:End Sequence:xs2 -> decodeASN1Err "RSA" bits xs2 (toPubKeyRSA . rsaPubFromASN1)
                _ -> Left ("fromASN1: X509.PubKey: unknown RSA format: " ++ show xs)
        | pkalg == getObjectID PubKeyALG_DSA   =
            case xs of
                Start Sequence:IntVal p:IntVal q:IntVal g:End Sequence:End Sequence:BitString bits:End Sequence:xs2 ->
                    decodeASN1Err "DSA" bits xs2 (\l -> case l of
                        [IntVal dsapub] ->
                            let pubkey = DSA.PublicKey { DSA.public_params = DSA.Params { DSA.params_p = p
                                                                                        , DSA.params_q = q
                                                                                        , DSA.params_g = g
                                                                                        }
                                                                           , DSA.public_y = dsapub }
                             in Right (PubKeyDSA pubkey, [])
                        _ -> Left "fromASN1: X509.PubKey: unknown DSA format"
                        )
                _ -> Left "fromASN1: X509.PubKey: unknown DSA format"
        | pkalg == getObjectID PubKeyALG_ECDSA =
            case xs of
                OID curveOid:End Sequence:BitString bits:End Sequence:xs2 ->
                    case lookupByOID curvesOIDTable curveOid of
                        Just curveName -> Right (PubKeyECDSA curveName (bitArrayGetData bits), xs2)
                        Nothing        -> Left ("fromASN1: X509.Pubkey: ECDSA unknown curve " ++ show curveOid)
                _ -> Left "fromASN1: X509.PubKey: unknown ECDSA format"
        | otherwise = error ("unknown public key OID: " ++ show pkalg)
      where decodeASN1Err format bits xs2 f =
                case decodeASN1' BER (bitArrayGetData bits) of
                    Left err -> Left ("fromASN1: X509.PubKey " ++ format ++ " bitarray cannot be parsed: " ++ show err)
                    Right s  -> case f s of
                                    Left err -> Left err
                                    Right (r, xsinner) -> Right (r, xsinner ++ xs2)
            toPubKeyRSA = either Left (\(rsaKey, r) -> Right (PubKeyRSA rsaKey, r))

            removeNull (Null:r) = r
            removeNull l        = l

    fromASN1 l = Left ("fromASN1: X509.PubKey: unknown format:" ++ show l)
    toASN1 a = \xs -> encodePK a ++ xs

-- | Convert a Public key to the Public Key Algorithm type
pubkeyToAlg :: PubKey -> PubKeyALG
pubkeyToAlg (PubKeyRSA _)         = PubKeyALG_RSA
pubkeyToAlg (PubKeyDSA _)         = PubKeyALG_DSA
pubkeyToAlg (PubKeyDH _)          = PubKeyALG_DH
pubkeyToAlg (PubKeyECDSA _ _)     = PubKeyALG_ECDSA
pubkeyToAlg (PubKeyUnknown oid _) = PubKeyALG_Unknown oid

encodePK :: PubKey -> [ASN1]
encodePK key = asn1Container Sequence (encodeInner key)
  where
    pkalg = OID $ getObjectID $ pubkeyToAlg key
    encodeInner (PubKeyRSA pubkey) =
        asn1Container Sequence [pkalg,Null] ++ [BitString $ toBitArray bits 0]
      where bits = encodeASN1' DER $ rsaPubToASN1 pubkey []
    encodeInner (PubKeyDSA pubkey) =
        asn1Container Sequence ([pkalg] ++ dsaseq) ++ [BitString $ toBitArray bits 0]
      where
        dsaseq = asn1Container Sequence [IntVal (DSA.params_p params)
                                        ,IntVal (DSA.params_q params)
                                        ,IntVal (DSA.params_g params)]
        params = DSA.public_params pubkey
        bits   = encodeASN1' DER [IntVal $ DSA.public_y pubkey]
    encodeInner (PubKeyECDSA curveName bits) =
        asn1Container Sequence [pkalg,OID eOid] ++ [BitString $ toBitArray bits 0]
      where
        eOid = case curveName of
                    ECC.SEC_p384r1 -> [1,3,132,0,34]
                    _              -> error ("undefined curve OID: " ++ show curveName)
    encodeInner (PubKeyDH _) = error "encodeInner: unimplemented public key DH"
    encodeInner (PubKeyUnknown _ l) =
        asn1Container Sequence [pkalg,Null] ++ [BitString $ toBitArray l 0]

rsaPubToASN1 :: RSA.PublicKey -> [ASN1] -> [ASN1]
rsaPubToASN1 pubkey xs =
    Start Sequence : IntVal (RSA.public_n pubkey) : IntVal (RSA.public_e pubkey) : End Sequence : xs

rsaPubFromASN1 :: [ASN1] -> Either String (RSA.PublicKey, [ASN1])
rsaPubFromASN1 (Start Sequence:IntVal smodulus:IntVal pubexp:End Sequence:xs) =
    Right (pub, xs)
  where
    pub = RSA.PublicKey { RSA.public_size = calculate_modulus modulus 1
                        , RSA.public_n    = modulus
                        , RSA.public_e    = pubexp
                        }
    calculate_modulus n i = if (2 ^ (i * 8)) > n then i else calculate_modulus n (i+1)
    -- some bad implementation will not serialize ASN.1 integer properly, leading
    -- to negative modulus. if that's the case, we correct it.
    modulus = toPositive smodulus

rsaPubFromASN1 ( Start Sequence
               : IntVal ver
               : Start Sequence
               : OID oid
               : Null
               : End Sequence
               : OctetString bs
               : xs
               )
    | ver /= 0 = Left "rsaPubFromASN1: Invalid version, expecting 0"
    | oid /= [1,2,840,113549,1,1,1] =
        Left "rsaPubFromASN1: invalid OID"
    | otherwise =
        let inner = either strError rsaPubFromASN1 $ decodeASN1' BER bs
            strError = Left . ("fromASN1: RSA.PublicKey: " ++) . show
         in either Left (\(k, _) -> Right (k, xs)) inner
rsaPubFromASN1 _ =
    Left "fromASN1: RSA.PublicKey: unexpected format"

-- some bad implementation will not serialize ASN.1 integer properly, leading
-- to negative modulus.
toPositive :: Integer -> Integer
toPositive int
    | int < 0   = uintOfBytes $ bytesOfInt int
    | otherwise = int
  where
    uintOfBytes = foldl (\acc n -> (acc `shiftL` 8) + fromIntegral n) 0
    bytesOfInt :: Integer -> [Word8]
    bytesOfInt n = if testBit (head nints) 7 then nints else 0xff : nints
      where nints = reverse $ plusOne $ reverse $ map complement $ bytesOfUInt (abs n)
            plusOne []     = [1]
            plusOne (x:xs) = if x == 0xff then 0 : plusOne xs else (x+1) : xs
    bytesOfUInt x = reverse (list x)
      where list i = if i <= 0xff then [fromIntegral i] else (fromIntegral i .&. 0xff) : list (i `shiftR` 8)
