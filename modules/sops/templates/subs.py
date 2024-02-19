from sys import argv


def substitute(target: str, subst: str) -> str:
    with open(target) as f:
        content = f.read()

    with open(subst) as f:
        subst_pairs = f.read().splitlines()

    for pair in subst_pairs:
        placeholder, path = pair.split()
        if placeholder in content:
            with open(path) as f:
                content = content.replace(placeholder, f.read())

    return content


def main() -> None:
    target = argv[1]
    subst = argv[2]
    print(substitute(target, subst))


main()
