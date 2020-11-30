#!/bin/bash

# Generate a current timestamp in the format expected for Hugo markdown files
date +"%Y-%m-%dT%H:%M:%S%z" | perl -ne 's/(\d{2})(\d{2})$/$1:$2/; print'
