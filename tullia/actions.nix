{
  "bitte/ci" = {
    task = "build";
    io = ''
      _lib: github: {
        #repo: "input-output-hk/bitte"
        push: {
          #branch: "bitte-tests"
          #default_branch: false
        }
      }
    '';
  };
}
