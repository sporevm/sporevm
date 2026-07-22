# buildkite-sporevm benchmark context

This is the build context from local `buildkite-sporevm` commit
`ad8967125968098b917090e49b6410dd5a6b19c5`, adapted to use a named OCI layout
as its `base` build context for the image-gateway transport benchmark. The benchmark adds
the generated dependency-image archives and DynamoDB Local distribution before
building it; their immutable inputs and checksums live in
`scripts/ci/image-gateway-buildkite-workload-benchmark.sh`.

The adapted files committed here have these SHA-256 digests:

```text
2307b73ef70b505155d0dde7f2a9d07e71bd59f312b3fdbc5e242eaf94926f5a  Dockerfile
acd0c102940807a801911695ebbb039b770b71a700759689dff8ef700db2fad6  compose-initdb/init.sql
031ed5b3cc3ece90f4c035445d78256a850e19ecbc786a02e75da6575f827728  compose.yaml
2ae46bc74fa6f2c51c1d4177db675527a9e1baec4102db9a930abf13edce19d7  image/bin/setup-spore
```
