import json
import subprocess
import time
import os

REGISTRY_FILE = "metamorph_scout_list.json"

def feed_julian():
    if not os.path.exists(REGISTRY_FILE):
        print(f"Error: {REGISTRY_FILE} not found.")
        return

    with open(REGISTRY_FILE, "r", encoding="utf-8") as f:
        packages = json.load(f)

    print(f"Loaded {len(packages)} packages from registry.")
    
    # We need to find the GitHub repo for each package.
    # For now, let's just look at the structure to see if they expose the repo URL.
    # If not, we can use Julian to search for the package name.
    
    for i, pkg in enumerate(packages[:5]):
        name = pkg.get("name")
        owner = pkg.get("ownerHandle")
        print(f"\n[{i+1}/5] Processing: {owner}/{name}")
        
        # Since the API doesn't explicitly give us the GitHub repo in the summary,
        # we will use Julian's scout-task to search for it, or we can construct a search query.
        # For now, let's just run a scout task to see if Julian already knows about it.
        
        cmd = f"python -m julian_metamorph.cli scout-task \"{name}\""
        print(f"Running: {cmd}")
        
        try:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
            print(result.stdout.strip())
        except Exception as e:
            print(f"Error: {e}")

if __name__ == "__main__":
    feed_julian()
