# Parse go.mod in Nix
# Returns a Nix structure with the contents of the go.mod passed in
# in normalised form.

let
  inherit (builtins) elemAt mapAttrs split foldl' match filter typeOf;

  # Strip lines with comments & other junk
  stripStr = s: elemAt (split "^ *" (elemAt (split " *$" s) 0)) 2;
  stripLines = initialLines: foldl' (acc: f: f acc) initialLines [
    # Strip comments
    (lines: map
      (l:
        let
          m = match "(.*)( |)//.*" l;
          hasComment = m != null;
        in
        stripStr (if hasComment then elemAt m 0 else l))
      lines)

    # Strip leading tabs characters
    (lines: map (l: elemAt (match "(\t|)(.*)" l) 1) lines)

    # Filter empty lines
    (filter (l: l != ""))
  ];

  # Parse lines into a structure
  parseLines = lines: (foldl'
    (acc: l:
      let
        m = match "([^ )]*) *(.*)" l;
        directive = elemAt m 0;
        rest = elemAt m 1;

        # Maintain parser state (inside parens or not)
        inDirective =
          if rest == "(" then directive
          else if rest == ")" then null
          else acc.inDirective
        ;

      in
      {
        data = acc.data // (
          if directive == "" && rest == ")" then { }
          else if inDirective != null && rest == "(" then {
            ${inDirective} = { };
          } else if inDirective != null then {
            ${inDirective} = acc.data.${inDirective} // { ${directive} = rest; };
          } else {
            ${directive} = rest;
          }
        );
        inherit inDirective;
      })
    {
      inDirective = null;
      data = { };
    }
    lines
  ).data;

  normaliseDirectives = data: (
    let
      normaliseString = s:
        let
          m = builtins.match "([^ ]+) (.+)" s;
        in
        {
          ${elemAt m 0} = elemAt m 1;
        };
      require = data.require or { };
      replace = data.replace or { };
      exclude = data.exclude or { };
    in
    data // {
      require =
        if typeOf require == "string" then normaliseString require
        else require;
      replace =
        if typeOf replace == "string" then normaliseString replace
        else replace;
    }
  );

  parseVersion = ver:
    let
      m = elemAt (match "([^-]+)-?([^-]*)-?([^-]*)" ver);
      v = elemAt (match "([^+]+)\\+?(.*)" (m 0));
    in
    {
      version = v 0;
      versionSuffix = v 1;
      date = m 1;
      rev = m 2;
    };

  parseReplace = data: (
    data // {
      replace =
        mapAttrs
          (n: v:
            let
              m = match "=> (.+?) (.+)" v;
              m2 = match "=> (.*+)" v;
            in
            if m != null then {
              goPackagePath = elemAt m 0;
              version = parseVersion (elemAt m 1);
            } else {
              path = elemAt m2 0;
            })
          data.replace;
    }
  );

  parseRequire = data: (
    data // {
      require = mapAttrs (n: v: parseVersion v) data.require;
    }
  );

  splitString = sep: s: filter (t: t != [ ]) (split sep s);

in
contents:
foldl' (acc: f: f acc) (splitString "\n" contents) [
  stripLines
  parseLines
  normaliseDirectives
  parseReplace
  parseRequire
]
