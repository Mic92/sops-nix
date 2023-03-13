from sys import argv

target = argv[1]
subst = "@subst@"

with open(target) as f:
    content = f.read()

with open(subst) as f:
    subst_pairs = f.read().splitlines()

for pair in subst_pairs:
    placeholder, path = pair.split()
    with open(path) as f:
        content = content.replace(placeholder, f.read())

print(content)
