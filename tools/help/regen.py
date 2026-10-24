# 帮助页由 help_zh.py、help_en.py（内容）和 helpxaml.py（排版）生成，写回 src/CleanC-UI.ps1 里的两份帮助 XAML。
# 改帮助只改这三个文件，然后：python3 tools/help/regen.py && python3 build/split.py
import os, sys; H = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, H)
import helpxaml, help_zh, help_en
P=os.path.join(H, '..', '..', 'src', 'CleanC-UI.ps1')
s=open(P,encoding='utf-8-sig',newline='').read().replace('\r\n','\n')
def risk_lines(seg):
    L=seg.split('\n'); i=next(k for k,l in enumerate(L) if '<Border x:Name="RiskCard"' in l)
    ind=len(L[i])-len(L[i].lstrip(' '))
    j=next(k for k in range(i+1,len(L)) if L[k]==' '*ind+'</Border>'); return [l[ind:] for l in L[i:j+1]]
a=s.index('    <!-- ==================== 帮助：使用说明、安全风险提示、使用反馈 ==================== -->')
b=s.index('\n\n    <!-- ==================== 底部：进度条',a)
zh=helpxaml.page(help_zh.PAGE,risk_lines(s[a:b])); assert '$' not in zh and '`' not in zh
s=s[:a]+zh+s[b:]
a=s.index("$script:helpEnXaml = @'\n")+len("$script:helpEnXaml = @'\n"); b=s.index("\n'@",a)
en=helpxaml.page(help_en.PAGE,risk_lines(s[a:b])); assert "\n'@" not in en; s=s[:a]+en+s[b:]
open(P,'w',encoding='utf-8-sig',newline='').write(s.replace('\n','\r\n')); print('regen ok')
