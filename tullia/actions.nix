{
  "bitte/ci" = {
    task = "build";
    io = ''
      _lib: github: {
        #repo: "input-output-hk/bitte"
        pull_request: {}
        push: {}
      }
    '';
  };
}
