module Tests.Unit
	( runTests
	) where

import System.Directory
import Test.HUnit
import Control.Monad
import Control.Applicative ((<$>))
import Control.Exception
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Certificate.X509
import Data.Certificate.PEM
import Data.List (isPrefixOf)

readAllSystemCertificates = do
	certfiles <- filter (not . isPrefixOf ".") <$> getDirectoryContents "/etc/ssl/certs"
	foldM getCertData [] certfiles 
	where getCertData acc certfile = do
		certdata <- try (B.readFile ("/etc/ssl/certs/" ++ certfile)) :: IO (Either IOException B.ByteString)
		case either (const Nothing) (parsePEMCert) $ certdata of
			Nothing -> return acc
			Just x  -> return ((certfile, x) : acc)

checkCert name rawCert (X509 c mraw sigalg sigbits) = do
	let errs =
		(checkSigAlg $ certSignatureAlg c) ++
		(checkPubKey $ certPubKey c) ++
		(checkExtensions $ certExtensions c) ++
		(checkBodyRaw rawCert mraw)
	when (errs /= []) $ do
		putStrLn ("error decoding " ++ name)
		mapM_ (putStrLn . ("  " ++))  errs
	where
		checkExtensions ext = []

		checkSigAlg (SignatureALG_Unknown oid) = ["unknown signature algorithm " ++ show oid]
		checkSigAlg _                          = []

		checkPubKey (PubKey (PubKeyALG_Unknown oid) _) = ["unknown public key alg " ++ show (certPubKey c)]
		checkPubKey (PubKey _ (PubKeyUnknown l))       = ["unknown public key " ++ show (certPubKey c)]
		checkPubKey (PubKey _ (PubKeyECDSA x))         = ["unknown public ECDSA key " ++ show x]
		checkPubKey _                                  = []

		checkBodyRaw x Nothing  = []
		checkBodyRaw x (Just y) = if findsubstring y x then [] else ["cannot find body cert in original raw file"]

		findsubstring a b
			| L.null b        = False
			| a `L.isPrefixOf` b = True
			| otherwise          = findsubstring a (L.drop 1 b)

runTests :: IO ()
runTests = do
	certs <- readAllSystemCertificates
	forM certs $ \(name, cert) -> do
		let rawCert = L.fromChunks [cert]
		case decodeCertificate rawCert of
			Left err -> putStrLn ("cannot decode certificate " ++ name ++ " " ++ show err)
			Right c  -> checkCert name rawCert c
	return ()