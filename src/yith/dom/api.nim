## Backend switch: the test tree for `nimony c -d:yithDomTest`, the browser
## bindings otherwise.

{.feature: "lenientnils".}
{.feature: "assumeSync".}

when defined(yithDomTest):
  include "test"
else:
  include "js"
