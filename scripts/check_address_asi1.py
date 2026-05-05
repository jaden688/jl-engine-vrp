from cosmpy.aerial.wallet import LocalWallet
from uagents.crypto import Identity
import base64

MNEMONIC = "conduct crowd text swear novel gesture depart term snack funny broccoli answer frozen broccoli carpet apology satisfy scan february spirit crawl average judge early"
wallet = LocalWallet.from_mnemonic(MNEMONIC)
identity = Identity.from_string(base64.b64decode(wallet.signer().private_key).hex())
print("Address:", identity.address)
