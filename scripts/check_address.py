from cosmpy.aerial.wallet import LocalWallet
from uagents.crypto import Identity
import base64
import os

from dotenv import load_dotenv

load_dotenv()

MNEMONIC = os.getenv("TRADER_WALLET_KEY")
if not MNEMONIC:
    raise RuntimeError("TRADER_WALLET_KEY is not set")
wallet = LocalWallet.from_mnemonic(MNEMONIC)
identity = Identity.from_string(base64.b64decode(wallet.signer().private_key).hex())
print("Address:", identity.address)
