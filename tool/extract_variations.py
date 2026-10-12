import re,sys,json
src=open(sys.argv[1]).read()
pairs=re.findall(r'Variation::(Group(\d+)Var(\d+)) => \((\d+), (\d+)\)',src)
desc=dict(re.findall(r'Variation::(Group\d+Var\d+) => "([^"]*)"',src))
desc0=re.findall(r'Variation::(Group\d+)\(_\) => "([^"]*)"',src)
out=[]
for name,g,v,g2,v2 in pairs:
    out.append((name,int(g2),int(v2),desc.get(name,'')))
json.dump({'fixed':out,'param':desc0},open(sys.argv[2],'w'),indent=0)
print(len(out),desc0)
