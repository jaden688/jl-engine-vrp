import os
from dotenv import load_dotenv
from uagents_core.utils.registration import (
    register_chat_agent,
    RegistrationRequestCredentials,
)

# Load environment variables from .env
load_dotenv()

SEED_PHRASE = "conduct crowd text swear novel gesture depart term snack funny broccoli answer frozen broccoli carpet apology satisfy scan february spirit crawl average judge early"
AGENTVERSE_KEY = os.environ.get("AGENTVERSE_API_KEY", "")

print("Registering SparkByte-1 with Agentverse and creating handle...")

if not AGENTVERSE_KEY:
    print("ERROR: AGENTVERSE_API_KEY is missing from .env!")
    exit(1)

try:
    register_chat_agent(
        "sparkbyte", # This becomes the handle!
        "https://5c13-2001-56a-7dfc-c300-a867-9d88-aecc-f0b7.ngrok-free.app/submit",
        active=True,
        credentials=RegistrationRequestCredentials(
            agentverse_api_key=AGENTVERSE_KEY,
            agent_seed_phrase=SEED_PHRASE,
        ),
    )
    print("Registration complete! Handle created and agent is officially on Agentverse!")
except Exception as e:
    print(f"Uh oh, something went wrong: {e}")
