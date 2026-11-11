## Backend switch: the test tree for `nimony c -d:yithDomTest`, the browser
## bindings otherwise.

{.feature: "lenientnils".}
{.feature: "assumeSync".}

type
  Rect* = object
    ## Border box in document coordinates. The browser backend reads
    ## `getBoundingClientRect`; the test backend runs a small CSS layout pass.
    x*, y*, w*, h*: float

when defined(yithDomTest):
  include "test"
else:
  include "js"
