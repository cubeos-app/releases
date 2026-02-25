# x86_64 Base Image

The x86_64 platform does **not** use a pre-built golden base image.

Unlike the Raspberry Pi build (which starts from a golden `.img` with all packages
pre-installed), the x86_64 build uses the official Ubuntu 24.04 Server ISO directly.
The Ubuntu autoinstall mechanism (`platforms/x86_64/http/user-data`) handles package
installation during the Packer build.

This means the x86_64 build takes longer (~15-20 minutes vs ~3-5 minutes for Pi)
because it includes a full Ubuntu installation step. The tradeoff is simpler
maintenance — no golden base image to rebuild when packages change.
