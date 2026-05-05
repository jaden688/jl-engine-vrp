import json
import subprocess
import time
import os

REGISTRY_FILE = "metamorph_scout_list.json"

def generate_hunt_list():
    if not os.path.exists(REGISTRY_FILE):
        print(f"Error: {REGISTRY_FILE} not found.")
        return

    with open(REGISTRY_FILE, "r", encoding="utf-8") as f:
        packages = json.load(f)

    print(f"Loaded {len(packages)} packages from registry.")
    
    # Filter out the ones that are just prompts (executesCode: false)
    # We want the actual code tools.
    code_packages = [p for p in packages if p.get("executesCode") is True]
    
    print(f"Found {len(code_packages)} packages that execute code.")
    
    # If there aren't many code packages in the first 500, we'll just take the top 20 overall
    # to give Julian some good targets.
    targets = code_packages if len(code_packages) > 0 else packages[:20]
    
    print("\n--- INITIATING JULIAN HUNT SEQUENCE ---")
    
    for i, pkg in enumerate(targets):
        name = pkg.get("name", "")
        display_name = pkg.get("displayName", name)
        summary = pkg.get("summary", "")
        
        # Create a highly specific search query for Julian
        # We want him to find the GitHub repo that implements this OpenClaw skill
        query = f"openclaw skill {name}"
        
        print(f"\n[{i+1}/{len(targets)}] Hunting for: {display_name}")
        print(f"Query: {query}")
        
        cmd = f"python -m julian_metamorph.cli hunt-task \"{query}\""
        
        try:
            # We use subprocess.Popen so we don't block forever if one hangs
            process = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            
            # Wait up to 60 seconds per hunt
            try:
                stdout, stderr = process.communicate(timeout=60)
                if stdout:
                    # Just print a summary of what he found, not the whole massive output
                    lines = stdout.split('\n')
                    print(f"Result: {lines[-2] if len(lines) > 1 else 'Done'}")
            except subprocess.TimeoutExpired:
                process.kill()
                print("Hunt timed out after 60 seconds. Moving to next.")
                
        except Exception as e:
            print(f"Error: {e}")
            
        # Give GitHub API a breather
        time.sleep(2)

if __name__ == "__main__":
    generate_hunt_list()
