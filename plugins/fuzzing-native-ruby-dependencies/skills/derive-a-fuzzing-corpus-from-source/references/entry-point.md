# Read the entry point first: the long form

SKILL.md step 3 states each check as an imperative. This is why each one pays, to read
when a sniffer family added nothing or you are choosing which format to write next.
Find the function that decides *what kind of input this is*, then:

* **Sniffers are looser than the formats they claim to detect.** Look for magic checks
  testing fewer bytes than the signature has, or skipping one. A seed at the sniffer's
  **minimum match**, often 2-12 bytes, is the cheapest coverage in the method.
* **Dispatch order is reachability.** If the dispatcher tests A before B, anything
  matching both never reaches B.
* **Short inputs.** A zero-padded fixed-size sniff buffer means sub-minimum inputs still
  reach every sniffer with defined values, hence lengths 0, 1, 2, 3 and the sniff width.
* **Anything that runs before the real codec** (metadata, container framing, checksum
  skipping) is in-tree, hand-written, rarely reviewed, and reachable behind two bytes of
  magic. That is why it comes first.
* **Supported formats with zero fixtures** are the biggest gap a sample corpus has, and
  mutation never closes it. A class name in `strings` can sit behind an `#ifdef` the
  build never defined, so verify the back end is registered before writing a family for
  it: one minimum-match probe settles it. A harness that prints **which back end was
  selected** makes the probe, and every later family, readable from `.results`.
