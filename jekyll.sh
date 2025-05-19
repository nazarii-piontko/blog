#!/bin/bash

docker run -it -v $(pwd):/blog -w /blog --network host --rm jekyll $@
