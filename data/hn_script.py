import urllib.request
import json
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

limit = 3
sent_file = os.path.join(os.getcwd(), 'data', 'hn_sent_ids.txt')

sent_ids = set()
if os.path.exists(sent_file):
    with open(sent_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                sent_ids.add(int(line))

req = urllib.request.Request('https://hacker-news.firebaseio.com/v0/topstories.json')
with urllib.request.urlopen(req) as response:
    top_ids = json.loads(response.read().decode())

new_posts = 0
for item_id in top_ids[:30]:
    if item_id not in sent_ids:
        req_item = urllib.request.Request(f'https://hacker-news.firebaseio.com/v0/item/{item_id}.json')
        with urllib.request.urlopen(req_item) as response:
            item = json.loads(response.read().decode())
            
        title = item.get('title', 'No Title')
        url = item.get('url', f'https://news.ycombinator.com/item?id={item_id}')
        score = item.get('score', 0)
        
        title = title.replace('\n', ' ')
        msg = f"🔥 HN Trending:\n{title}\nScore: {score}\n{url}"
        
        print(f"{item_id}<SEP>{msg}")
        
        sent_ids.add(item_id)
        with open(sent_file, 'a') as f:
            f.write(f"{item_id}\n")
            
        new_posts += 1
        if new_posts >= limit:
            break
