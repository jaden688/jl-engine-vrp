import requests
import json
import time
import os

API_URL = "https://clawhub.ai/api/v1/packages"
OUTPUT_FILE = "metamorph_scout_list.json"
LIMIT = 100

def fetch_packages():
    print(f"Starting ClawHub registry scrape...")
    all_packages = []
    offset = 0
    
    while True:
        print(f"Fetching packages {offset} to {offset + LIMIT}...")
        try:
            response = requests.get(f"{API_URL}?limit={LIMIT}&offset={offset}", timeout=10)
            response.raise_for_status()
            data = response.json()
            
            items = data.get("items", [])
            if not items:
                break
                
            all_packages.extend(items)
            offset += LIMIT
            
            # Be polite to their API
            time.sleep(0.5)
            
            # For testing, let's just grab the first 500 so we don't wait forever
            if offset >= 500:
                print("Reached 500 packages (test limit). Stopping.")
                break
                
        except Exception as e:
            print(f"Error fetching at offset {offset}: {e}")
            break
            
    print(f"Successfully fetched {len(all_packages)} packages.")
    
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        json.dump(all_packages, f, indent=2, ensure_ascii=False)
        
    print(f"Saved to {OUTPUT_FILE}")

if __name__ == "__main__":
    fetch_packages()
