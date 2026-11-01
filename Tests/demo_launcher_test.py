import os,pathlib,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class DemoLauncher(unittest.TestCase):
 def test_separate_home_and_no_service_controls(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp);(p/'converse-demo').write_bytes((ROOT/'linux/demo.sh').read_bytes());(p/'converse-demo').chmod(0o700)
   (p/'converse').write_text('#!/bin/sh\nprintf "%s\\n" "$CONVERSE_LINUX_HOME" "$CONVERSE_LINUX_PORT" "$CONVERSE_DEMO" "$1"\n');(p/'converse').chmod(0o700)
   env=dict(os.environ,CONVERSE_DEMO_HOME=str(p/'isolated'),CONVERSE_LINUX_HOME='/production')
   result=subprocess.run([str(p/'converse-demo'),'serve'],env=env,text=True,capture_output=True,check=True)
   self.assertEqual(result.stdout.splitlines(),[str(p/'isolated'),'0','1','serve'])
   for command in ['install-self','service-start','service-stop','supervise']:
    result=subprocess.run([str(p/'converse-demo'),command],env=env,capture_output=True)
    self.assertEqual(result.returncode,64)
    self.assertEqual(result.stdout,b'')
if __name__=='__main__':unittest.main()
