"""Super Research — iOS track.

⛔ **A8:** nothing outside this repo is modified. ``dg-research-backend`` and
``dg-research`` are read-only; :mod:`emubackend.berepo` is the only sanctioned way to
reach BE code, and :mod:`emubackend.purity` mechanically proves we kept the promise.

Every top-level name this repo owns lives under this one package, because putting the BE
checkout on ``sys.path`` claims ``research``, ``models``, ``prompts``, ``vision``,
``vision_test``, ``narrate``, ``selfheal``, ``auth`` and ``scripts`` — and also makes
``tests``, ``tools`` and ``agent`` unsafe as top-level directory names, since Python 3
would merge same-named plain directories into one implicit namespace package.
"""

__all__ = ["__version__"]

__version__ = "0.0.1"
