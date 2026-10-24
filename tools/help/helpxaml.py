# 帮助页 XAML 生成：每一节一张能折叠的卡片，条目是粗体标题加一两行说明
import re

def esc(s): return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
def qa(s): return esc(s).replace('"', '&quot;')

def runs(s):
    out = []
    for i, p in enumerate(s.split('**')):
        if not p: continue
        if i % 2: out.append('<Run FontWeight="SemiBold" Foreground="#1D1D1F">%s</Run>' % esc(p))
        else: out.append('<Run>%s</Run>' % esc(p))
    return ''.join(out)

# 内容块
def G(t): return ('group', t)
def I(lead, body=None, subs=(), lvl=0): return ('item', lead, body, list(subs), lvl)   # lvl：1 工程师、2 开发者和 IT 模式才有的功能
def N(kind, lead, body): return ('note', kind, lead, body)
def K(rows, w): return ('keys', rows, w)
def F(lead, steps, after=None): return ('flow', lead, steps, after)
def T(tiles): return ('tiles', tiles)
def P(t): return ('para', t)
def B(items): return ('bullets', items)

NOTE = {
    'warn': ('#FFF8EC', '#F5E1BC', '&#xE7BA;', '#B25E00'),
    'safe': ('#EFF8F1', '#CFE9D6', '&#xEA18;', '#248A3D'),
    'info': ('#EEF5FD', '#D2E3FA', '&#xE946;', '#0071E3'),
    'lock': ('#F5F5F7', '#E5E5EA', '&#xE72E;', '#6E6E73'),
}
TONE = {
    None:    (None, '#1D1D1F'),
    'green': ('#E5F4E9', '#1D7A35'),
    'red':   ('#FDEBEC', '#C0101C'),
    'amber': ('#FFF1DB', '#995700'),
    'blue':  ('#E8F1FC', '#0B5CAD'),
}

class W:
    def __init__(s, ind): s.L = []; s.i = ind
    def __call__(s, line): s.L.append(' ' * s.i + line)
    def push(s, line): s(line); s.i += 2
    def pop(s, line): s.i -= 2; s(line)

def sub(w, t, top):
    w('<DockPanel Margin="0,%d,0,0"><TextBlock DockPanel.Dock="Left" Text="•" Width="20" Style="{StaticResource HelpBody}" Margin="2,0,0,0" Foreground="#8E8E93"/><TextBlock Style="{StaticResource HelpBody}" Margin="0">%s</TextBlock></DockPanel>' % (top, runs(t)))

def tiles(w, items, top, numbered=False):
    # 方块按窗口宽度排成 1 到 4 列（由程序在窗口变宽、变窄时重新排）
    w.push('<Grid Tag="%s" Margin="0,%d,0,0">' % ('cols:230:12:12:4' if numbered else 'cols:280:12:12:3', top))
    for k, t in enumerate(items):
        lead, body = t[0], t[1]
        lvl = t[2] if len(t) > 2 else 0
        w.push('<Border Style="{StaticResource HelpTile}"%s>' % (' Tag="lvl:%d"' % lvl if lvl else ''))
        if numbered:
            w.push('<DockPanel>')
            w('<Border DockPanel.Dock="Left" Width="24" Height="24" CornerRadius="12" Background="#0071E3" VerticalAlignment="Top" Margin="0,0,12,0"><TextBlock Text="%d" Foreground="White" FontSize="12.5" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>' % (k + 1))
        w.push('<StackPanel>')
        w('<TextBlock Style="{StaticResource HelpLead}" Text="%s"%s/>' % (qa(lead), ' Margin="0,1,0,0"' if numbered else ''))
        w('<TextBlock Style="{StaticResource HelpBody}">%s</TextBlock>' % runs(body))
        w.pop('</StackPanel>')
        if numbered: w.pop('</DockPanel>')
        w.pop('</Border>')
    w.pop('</Grid>')

# 一组里连着的几条说明：窗口宽的时候排成两三列，窄的时候一列
ITEM_COLS = 'cols:330:44:26:3'
def item_panel(w, b):
    _, lead, body, subs, lvl = b
    # 当前模式看不到的功能：程序按 Tag 把这一条藏起来（换到那个模式才显示）
    w.push('<StackPanel%s>' % (' Tag="lvl:%d"' % lvl if lvl else ''))
    w('<TextBlock Style="{StaticResource HelpLead}" Text="%s"/>' % qa(lead))
    if body: w('<TextBlock Style="{StaticResource HelpBody}">%s</TextBlock>' % runs(body))
    for j, t in enumerate(subs): sub(w, t, 10 if j == 0 else 7)
    w.pop('</StackPanel>')

def blocks(w, bl):
    prev = None; i = 0
    while i < len(bl):
        b = bl[i]; kind = b[0]; i += 1
        top = 18 if prev is None else (14 if prev in ('group', 'para') else 26)
        if kind == 'group':
            top = 22 if prev is None else 40
            w('<TextBlock Text="%s" Style="{StaticResource HelpGroup}" Margin="0,%d,0,0"/>' % (qa(b[1]), top))
        elif kind == 'item':
            run = [b]
            while i < len(bl) and bl[i][0] == 'item': run.append(bl[i]); i += 1
            w.push('<Grid Tag="%s" Margin="0,%d,0,0">' % (ITEM_COLS, top))
            for it in run: item_panel(w, it)
            w.pop('</Grid>')
        elif kind == 'para':
            w('<TextBlock Style="{StaticResource HelpBody}" Margin="0,%d,0,0">%s</TextBlock>' % (top, runs(b[1])))
        elif kind == 'bullets':
            for j, s in enumerate(b[1]): sub(w, s, (top if prev is not None else 0) if j == 0 else 7)
        elif kind == 'note':
            _, k, lead, body = b
            bg, bd, ic, fg = NOTE[k]
            w.push('<Border Background="%s" BorderBrush="%s" BorderThickness="1" CornerRadius="12" Padding="18,16,22,17" Margin="0,%d,0,0">' % (bg, bd, top))
            w.push('<DockPanel>')
            w('<TextBlock DockPanel.Dock="Left" Text="%s" FontFamily="{StaticResource Icons}" FontSize="16" Foreground="%s" VerticalAlignment="Top" Margin="0,3,14,0"/>' % (ic, fg))
            w.push('<StackPanel>')
            w('<TextBlock Style="{StaticResource HelpLead}" Text="%s"/>' % qa(lead))
            w('<TextBlock Style="{StaticResource HelpBody}" MaxWidth="Infinity">%s</TextBlock>' % runs(body))
            w.pop('</StackPanel>')
            w.pop('</DockPanel>')
            w.pop('</Border>')
        elif kind == 'keys':
            # 标签加说明，一行一对；窗口宽的时候排成两列
            _, rows, width = b
            w.push('<Grid Tag="cols:400:40:16:2" Margin="0,%d,0,0">' % top)
            for row in rows:
                label, body = row[0], row[1]
                bg, fg = TONE[row[2] if len(row) > 2 else None]
                bga = ' Background="%s"' % bg if bg else ''
                w.push('<DockPanel>')
                w('<Border DockPanel.Dock="Left" Width="%d" VerticalAlignment="Top"><Border Style="{StaticResource HelpPill}"%s><TextBlock Text="%s" FontSize="13" Foreground="%s" TextWrapping="Wrap"/></Border></Border>' % (width, bga, qa(label), fg))
                w('<TextBlock Style="{StaticResource HelpBody}" Margin="0">%s</TextBlock>' % runs(body))
                w.pop('</DockPanel>')
            w.pop('</Grid>')
        elif kind == 'flow':
            _, lead, steps, after = b
            w.push('<StackPanel Margin="0,%d,0,0">' % top)
            w('<TextBlock Style="{StaticResource HelpLead}" Text="%s"/>' % qa(lead))
            w.push('<WrapPanel Margin="0,12,0,0">')
            for j, st in enumerate(steps):
                if j: w('<TextBlock Text="&#xE76C;" FontFamily="{StaticResource Icons}" FontSize="10" Foreground="#8E8E93" VerticalAlignment="Center" Margin="8,0,8,8"/>')
                w('<Border Style="{StaticResource HelpPill}" Background="#E8F1FC" Margin="0,0,0,8"><StackPanel Orientation="Horizontal"><TextBlock Text="%d" FontSize="13" FontWeight="SemiBold" Foreground="#0B5CAD"/><TextBlock Text="%s" FontSize="13" Foreground="#0B5CAD" Margin="7,0,0,0"/></StackPanel></Border>' % (j + 1, qa(st)))
            w.pop('</WrapPanel>')
            if after: w('<TextBlock Style="{StaticResource HelpBody}" Margin="0,4,0,0">%s</TextBlock>' % runs(after))
            w.pop('</StackPanel>')
        elif kind == 'tiles':
            tiles(w, b[1], top)
        prev = kind

def section(w, sec):
    w.push('<Expander Style="{StaticResource HelpSection}">')
    w.push('<Expander.Header>')
    w.push('<DockPanel>')
    w('<Border DockPanel.Dock="Left" Style="{StaticResource HelpIcon}"><TextBlock Text="%s" FontFamily="{StaticResource Icons}" FontSize="17" Foreground="#0071E3" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>' % sec['icon'])
    w.push('<StackPanel VerticalAlignment="Center">')
    w('<TextBlock Text="%s" Style="{StaticResource HelpHead}" HorizontalAlignment="Left"/>' % qa(sec['title']))
    w('<TextBlock Text="%s" Style="{StaticResource HelpSum}"/>' % qa(sec['sum']))
    w.pop('</StackPanel>')
    w.pop('</DockPanel>')
    w.pop('</Expander.Header>')
    w.push('<StackPanel>')
    blocks(w, sec['blocks'])
    w.pop('</StackPanel>')
    w.pop('</Expander>')

def card_head(w, icon, title):
    w('<StackPanel Orientation="Horizontal"><TextBlock Text="%s" FontFamily="{StaticResource Icons}" FontSize="19" Foreground="#0071E3" VerticalAlignment="Center" Margin="0,1,12,0"/><TextBlock Text="%s" Style="{StaticResource HelpHead}"/></StackPanel>' % (icon, qa(title)))

def page_cards(pg, risk):
    w = W(4)
    w(pg['comment'])
    w.push('<Grid x:Name="PageHelp" Grid.Column="1" Grid.Row="0" Visibility="Collapsed">')
    w.push('<ScrollViewer x:Name="HelpScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">')
    w.push('<StackPanel Margin="30,24,30,28" MaxWidth="880" HorizontalAlignment="Left">')
    w('<TextBlock Text="%s" Style="{StaticResource PageTitle}"/>' % qa(pg['title']))
    w('<TextBlock Style="{StaticResource PageSub}" Text="%s"/>' % qa(pg['sub']))
    for l in risk: w.L.append(' ' * w.i + l)
    # 快速上手
    w.push('<Border Style="{StaticResource Card}" Padding="22,18,22,22" Margin="0,16,0,0">')
    w.push('<StackPanel>')
    card_head(w, '&#xE768;', pg['quick_title'])
    tiles(w, pg['quick'], 14, numbered=True)
    w.pop('</StackPanel>')
    w.pop('</Border>')
    # 各功能
    w.push('<DockPanel Margin="2,30,2,10">')
    w('<Button x:Name="BtnHelpExpand" DockPanel.Dock="Right" Style="{StaticResource LinkButton}" Content="%s" FontSize="12.5" VerticalAlignment="Bottom"/>' % qa(pg['expand']))
    w('<TextBlock Text="%s" Style="{StaticResource HelpListHead}"/>' % qa(pg['features']))
    w.pop('</DockPanel>')
    w.push('<StackPanel x:Name="HelpSections">')
    for s in pg['sections']: section(w, s)
    w.pop('</StackPanel>')
    # 常见问题
    w('<TextBlock Text="%s" Style="{StaticResource HelpListHead}" Margin="2,30,2,10"/>' % qa(pg['faq_title']))
    w.push('<Border Style="{StaticResource Card}" Padding="22,2,22,4">')
    w.push('<StackPanel x:Name="HelpFaq">')
    for k, (q, ans) in enumerate(pg['faq']):
        w.push('<Expander Style="{StaticResource HelpQ}"%s>' % (' BorderThickness="0"' if k == 0 else ''))
        w('<Expander.Header><TextBlock Style="{StaticResource HelpLead}" Text="%s"/></Expander.Header>' % qa(q))
        w.push('<StackPanel>')
        prev = None
        for a in ans:
            if isinstance(a, str): a = P(a)
            top = 0 if prev is None else 8
            if a[0] == 'para': w('<TextBlock Style="{StaticResource HelpBody}" Margin="0,%d,0,0">%s</TextBlock>' % (top, runs(a[1])))
            else:
                for j, s in enumerate(a[1]): sub(w, s, (0 if prev is None else 6) if j == 0 else 3)
            prev = a[0]
        w.pop('</StackPanel>')
        w.pop('</Expander>')
    w.pop('</StackPanel>')
    w.pop('</Border>')
    # 使用反馈
    fb = pg['fb']
    w.push('<Border x:Name="FeedbackCard" Style="{StaticResource Card}" Padding="22,18,22,22" Margin="0,30,0,0">')
    w.push('<StackPanel>')
    card_head(w, '&#xE8BD;', fb['title'])
    w('<TextBlock Style="{StaticResource HelpBody}" Margin="0,8,0,0" Text="%s"/>' % qa(fb['intro']))
    w.push('<Border Background="#F5F5F7" CornerRadius="10" Padding="18,14" Margin="0,14,0,0">')
    w.push('<DockPanel>')
    w.push('<StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">')
    w('<Button x:Name="BtnIssue" Content="%s" Style="{StaticResource Primary}" Padding="14,7" Margin="0,0,8,0"/>' % qa(fb['issue']))
    w('<Button x:Name="BtnGitHub" Content="%s" Padding="14,7"/>' % qa(fb['home']))
    w.pop('</StackPanel>')
    w.push('<StackPanel Orientation="Horizontal" VerticalAlignment="Center">')
    w.push('<Border Width="40" Height="40" CornerRadius="20" Background="#E8F0FE">')
    w('<TextBlock Text="&#xE943;" FontFamily="{StaticResource Icons}" FontSize="18" Foreground="#0071E3" HorizontalAlignment="Center" VerticalAlignment="Center"/>')
    w.pop('</Border>')
    w.push('<StackPanel Margin="14,0,0,0" VerticalAlignment="Center">')
    w('<TextBlock Text="%s" Style="{StaticResource Caption}"/>' % qa(fb['ghcap']))
    w('<TextBlock x:Name="GitHubUrl" Text="github.com/Xuanqiyun/ClearC" FontSize="16" FontWeight="SemiBold" Margin="0,1,0,0" TextOptions.TextFormattingMode="Ideal"/>')
    w.pop('</StackPanel>')
    w.pop('</StackPanel>')
    w.pop('</DockPanel>')
    w.pop('</Border>')
    for j, (lead, body, btns) in enumerate(fb['items']):
        w.push('<StackPanel x:Name="Fb%s" Margin="0,18,0,0">' % btns[0][0][3:])
        if j: w('<Border Height="1" Background="#EDEDF0" Margin="0,0,0,18"/>')
        w('<TextBlock Style="{StaticResource HelpLead}" Text="%s"/>' % qa(lead))
        w('<TextBlock Style="{StaticResource HelpBody}" Text="%s"/>' % qa(body))
        w.push('<StackPanel Orientation="Horizontal" Margin="0,10,0,0">')
        for k, (name, text) in enumerate(btns):
            if name == 'CopyHint': w('<TextBlock x:Name="CopyHint" Style="{StaticResource Caption}" Foreground="#248A3D" Margin="14,0,0,0"/>')
            else: w('<Button x:Name="%s" Content="%s"%s/>' % (name, qa(text), ' Margin="0,0,8,0"' if k < len(btns) - 1 and btns[k + 1][0] != 'CopyHint' else ''))
        w.pop('</StackPanel>')
        w.pop('</StackPanel>')
    w.pop('</StackPanel>')
    w.pop('</Border>')
    w.pop('</StackPanel>')
    w.pop('</ScrollViewer>')
    w.pop('</Grid>')
    return '\n'.join(w.L)

# ---- 3.5：左边目录、右边只显示点开的那一项（和设置页一样） ----
def nav_item(w, name, tag, text):
    w('<RadioButton x:Name="%s" GroupName="helpnav" Tag="%s" Style="{StaticResource TreeItem}" ToolTip="%s"><TextBlock Text="%s" TextTrimming="CharacterEllipsis"/></RadioButton>' % (name, tag, qa(text), qa(text)))

def faq_body(w, pg):
    w.push('<StackPanel x:Name="HelpFaq" Margin="0,14,0,0">')
    for k, (q, ans) in enumerate(pg['faq']):
        w.push('<Expander Style="{StaticResource HelpQ}"%s>' % (' BorderThickness="0"' if k == 0 else ''))
        w('<Expander.Header><TextBlock Style="{StaticResource HelpLead}" Text="%s"/></Expander.Header>' % qa(q))
        w.push('<StackPanel>')
        prev = None
        for a in ans:
            if isinstance(a, str): a = P(a)
            top = 0 if prev is None else 10
            if a[0] == 'para': w('<TextBlock Style="{StaticResource HelpBody}" Margin="0,%d,0,0">%s</TextBlock>' % (top, runs(a[1])))
            else:
                for j, s in enumerate(a[1]): sub(w, s, (0 if prev is None else 8) if j == 0 else 7)
            prev = a[0]
        w.pop('</StackPanel>')
        w.pop('</Expander>')
    w.pop('</StackPanel>')

def feedback_card(w, fb):
    w.push('<Border x:Name="FeedbackCard" Style="{StaticResource Card}" Padding="36,30,36,36" Visibility="Collapsed">')
    w.push('<StackPanel>')
    card_head(w, '&#xE8BD;', fb['title'])
    w('<TextBlock Style="{StaticResource HelpBody}" Margin="0,12,0,0" Text="%s"/>' % qa(fb['intro']))
    w.push('<Border Background="#F5F5F7" CornerRadius="12" Padding="20,16" Margin="0,18,0,0">')
    w.push('<DockPanel>')
    w.push('<StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">')
    w('<Button x:Name="BtnIssue" Content="%s" Style="{StaticResource Primary}" Padding="14,7" Margin="0,0,8,0"/>' % qa(fb['issue']))
    w('<Button x:Name="BtnGitHub" Content="%s" Padding="14,7"/>' % qa(fb['home']))
    w.pop('</StackPanel>')
    w.push('<StackPanel Orientation="Horizontal" VerticalAlignment="Center">')
    w.push('<Border Width="40" Height="40" CornerRadius="20" Background="#E8F0FE">')
    w('<TextBlock Text="&#xE943;" FontFamily="{StaticResource Icons}" FontSize="18" Foreground="#0071E3" HorizontalAlignment="Center" VerticalAlignment="Center"/>')
    w.pop('</Border>')
    w.push('<StackPanel Margin="14,0,0,0" VerticalAlignment="Center">')
    w('<TextBlock Text="%s" Style="{StaticResource Caption}"/>' % qa(fb['ghcap']))
    w('<TextBlock x:Name="GitHubUrl" Text="github.com/Xuanqiyun/ClearC" FontSize="16" FontWeight="SemiBold" Margin="0,1,0,0" TextOptions.TextFormattingMode="Ideal"/>')
    w.pop('</StackPanel>')
    w.pop('</StackPanel>')
    w.pop('</DockPanel>')
    w.pop('</Border>')
    for j, (lead, body, btns) in enumerate(fb['items']):
        w.push('<StackPanel x:Name="Fb%s" Margin="0,24,0,0">' % btns[0][0][3:])
        if j: w('<Border Height="1" Background="#EDEDF0" Margin="0,0,0,24"/>')
        w('<TextBlock Style="{StaticResource HelpLead}" Text="%s"/>' % qa(lead))
        w('<TextBlock Style="{StaticResource HelpBody}" Text="%s"/>' % qa(body))
        w.push('<StackPanel Orientation="Horizontal" Margin="0,14,0,0">')
        for k, (name, text) in enumerate(btns):
            if name == 'CopyHint': w('<TextBlock x:Name="CopyHint" Style="{StaticResource Caption}" Foreground="#248A3D" Margin="14,0,0,0"/>')
            else: w('<Button x:Name="%s" Content="%s"%s/>' % (name, qa(text), ' Margin="0,0,8,0"' if k < len(btns) - 1 and btns[k + 1][0] != 'CopyHint' else ''))
        w.pop('</StackPanel>')
        w.pop('</StackPanel>')
    w.pop('</StackPanel>')
    w.pop('</Border>')

def page(pg, risk):
    w = W(4)
    w(pg['comment'])
    secs = pg['sections']; tree = pg['tree']
    w.push('<Grid x:Name="PageHelp" Grid.Column="1" Grid.Row="0" Visibility="Collapsed" Margin="30,24,30,14">')
    w('<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>')
    w.push('<StackPanel Grid.Row="0" Margin="0,0,0,16">')
    w('<TextBlock Text="%s" Style="{StaticResource PageTitle}"/>' % qa(pg['title']))
    w('<TextBlock Style="{StaticResource PageSub}" Text="%s"/>' % qa(pg['sub']))
    w.pop('</StackPanel>')
    w.push('<Grid Grid.Row="1">')
    w('<Grid.ColumnDefinitions><ColumnDefinition Width="214"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>')
    # 左边目录：一级标题（开始、清理、分析、管理、其他）下面一项一项
    w.push('<Border Grid.Column="0" Style="{StaticResource Card}" Padding="8,0,8,10" Margin="0,0,16,0" VerticalAlignment="Top">')
    w.push('<ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">')
    w.push('<StackPanel x:Name="HelpNav">')
    for head, keys in tree:
        w('<TextBlock Text="%s" Style="{StaticResource TreeHead}"/>' % qa(head))
        for k in keys:
            if k == 'start': nav_item(w, 'HelpNavStart', 'start', pg['quick_title'])
            elif k == 'faq': nav_item(w, 'HelpNavFaq', 'faq', pg['faq_title'])
            elif k == 'fb': nav_item(w, 'HelpNavFb', 'fb', pg['fb_nav'])
            else: nav_item(w, 'HelpNav%d' % k, 's%d' % k, secs[k].get('nav', secs[k]['title']))
    w.pop('</StackPanel>')
    w.pop('</ScrollViewer>')
    w.pop('</Border>')
    # 右边：只显示选中的那一项
    w.push('<ScrollViewer x:Name="HelpScroll" Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">')
    w.push('<StackPanel Margin="0,0,6,14">')
    w.push('<StackPanel x:Name="HelpPaneStart">')
    for k, l in enumerate(risk): w.L.append(' ' * w.i + (l.replace(' Margin="0,20,0,0"', ' Margin="0"') if k == 0 else l))
    w.push('<Border Style="{StaticResource Card}" Padding="36,30,36,36" Margin="0,20,0,0">')
    w.push('<StackPanel>')
    card_head(w, '&#xE768;', pg['quick_title'])
    tiles(w, pg['quick'], 20, numbered=True)
    w.pop('</StackPanel>')
    w.pop('</Border>')
    w.pop('</StackPanel>')
    w.push('<StackPanel x:Name="HelpSections">')
    for i, sec in enumerate(secs):
        w.push('<Border x:Name="HelpSec%d" Style="{StaticResource Card}" Padding="36,30,36,36" Visibility="Collapsed">' % i)
        w.push('<StackPanel>')
        w.push('<DockPanel>')
        w('<Border DockPanel.Dock="Left" Style="{StaticResource HelpIcon}"><TextBlock Text="%s" FontFamily="{StaticResource Icons}" FontSize="20" Foreground="#0071E3" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>' % sec['icon'])
        w.push('<StackPanel VerticalAlignment="Center">')
        w('<TextBlock Text="%s" Style="{StaticResource HelpHead}" HorizontalAlignment="Left"/>' % qa(sec['title']))
        w('<TextBlock Text="%s" Style="{StaticResource HelpSum}"/>' % qa(sec['sum']))
        w.pop('</StackPanel>')
        w.pop('</DockPanel>')
        w('<Border Height="1" Background="#EDEDF0" Margin="0,24,0,6"/>')
        blocks(w, sec['blocks'])
        w.pop('</StackPanel>')
        w.pop('</Border>')
    w.pop('</StackPanel>')
    w.push('<Border x:Name="HelpPaneFaq" Style="{StaticResource Card}" Padding="36,30,36,20" Visibility="Collapsed">')
    w.push('<StackPanel>')
    card_head(w, '&#xE897;', pg['faq_title'])
    faq_body(w, pg)
    w.pop('</StackPanel>')
    w.pop('</Border>')
    feedback_card(w, pg['fb'])
    # 上一项、下一项
    w.push('<DockPanel x:Name="HelpPager" Margin="4,14,4,0" LastChildFill="False">')
    w('<Button x:Name="BtnHelpNext" DockPanel.Dock="Right" Style="{StaticResource LinkButton}" FontSize="13"/>')
    w('<Button x:Name="BtnHelpPrev" DockPanel.Dock="Left" Style="{StaticResource LinkButton}" FontSize="13"/>')
    w.pop('</DockPanel>')
    w.pop('</StackPanel>')
    w.pop('</ScrollViewer>')
    w.pop('</Grid>')
    w.pop('</Grid>')
    return '\n'.join(w.L)

STYLES = r'''
    <!-- 帮助页：每一节是一张能折叠的卡片；条目是一行粗体标题，下面一两行说明 -->
    <Style x:Key="HelpLead" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#1D1D1F"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="HelpBody" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#515154"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="21"/>
      <Setter Property="Margin" Value="0,3,0,0"/>
      <Setter Property="MaxWidth" Value="720"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
    </Style>
    <Style x:Key="HelpGroup" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#0066CC"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="HelpSum" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Foreground" Value="#6E6E73"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,2,0,0"/>
    </Style>
    <Style x:Key="HelpListHead" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#6E6E73"/>
      <Setter Property="VerticalAlignment" Value="Bottom"/>
    </Style>
    <Style x:Key="HelpIcon" TargetType="Border">
      <Setter Property="Width" Value="36"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Background" Value="#EAF2FD"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,14,0"/>
    </Style>
    <Style x:Key="HelpPill" TargetType="Border">
      <Setter Property="Background" Value="#F0F0F3"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="8,1,8,2"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="Margin" Value="0,1,12,0"/>
    </Style>
    <Style x:Key="HelpTile" TargetType="Border">
      <Setter Property="Background" Value="#F5F5F7"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="14,11,14,13"/>
    </Style>
    <Style x:Key="HelpSection" TargetType="Expander">
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Expander">
            <Border Background="White" BorderBrush="#E5E5EA" BorderThickness="1" CornerRadius="12">
              <DockPanel>
                <ToggleButton DockPanel.Dock="Top" Focusable="False" Cursor="Hand" Content="{TemplateBinding Header}"
                              IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                  <ToggleButton.Template>
                    <ControlTemplate TargetType="ToggleButton">
                      <Border x:Name="Hd" Background="Transparent" CornerRadius="11" Padding="16,13,20,13">
                        <DockPanel>
                          <TextBlock x:Name="Chev" DockPanel.Dock="Right" Text="&#xE70D;" FontFamily="{StaticResource Icons}" FontSize="12"
                                     Foreground="#86868B" VerticalAlignment="Center" Margin="14,0,0,0" RenderTransformOrigin="0.5,0.5">
                            <TextBlock.RenderTransform><RotateTransform Angle="0"/></TextBlock.RenderTransform>
                          </TextBlock>
                          <ContentPresenter VerticalAlignment="Center"/>
                        </DockPanel>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chev" Property="Foreground" Value="#0071E3"/></Trigger>
                        <MultiTrigger>
                          <MultiTrigger.Conditions><Condition Property="IsMouseOver" Value="True"/><Condition Property="IsChecked" Value="False"/></MultiTrigger.Conditions>
                          <Setter TargetName="Hd" Property="Background" Value="#F7F7F9"/>
                        </MultiTrigger>
                        <Trigger Property="IsChecked" Value="True">
                          <Setter TargetName="Chev" Property="RenderTransform"><Setter.Value><RotateTransform Angle="180"/></Setter.Value></Setter>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </ToggleButton.Template>
                </ToggleButton>
                <StackPanel x:Name="Body" Visibility="Collapsed">
                  <Border Height="1" Background="#EDEDF0" Margin="16,0,16,0"/>
                  <ContentPresenter Margin="22,0,22,20"/>
                </StackPanel>
              </DockPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="True"><Setter TargetName="Body" Property="Visibility" Value="Visible"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- 常见问题：一行一个问题，点开看答案 -->
    <Style x:Key="HelpQ" TargetType="Expander">
      <Setter Property="BorderBrush" Value="#EDEDF0"/>
      <Setter Property="BorderThickness" Value="0,1,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Expander">
            <Border BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <DockPanel>
                <ToggleButton DockPanel.Dock="Top" Focusable="False" Cursor="Hand" Content="{TemplateBinding Header}"
                              IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                  <ToggleButton.Template>
                    <ControlTemplate TargetType="ToggleButton">
                      <Border Background="Transparent" Padding="0,13,2,13">
                        <DockPanel>
                          <TextBlock x:Name="Chev" DockPanel.Dock="Right" Text="&#xE70D;" FontFamily="{StaticResource Icons}" FontSize="11"
                                     Foreground="#86868B" VerticalAlignment="Center" Margin="16,0,0,0" RenderTransformOrigin="0.5,0.5">
                            <TextBlock.RenderTransform><RotateTransform Angle="0"/></TextBlock.RenderTransform>
                          </TextBlock>
                          <ContentPresenter VerticalAlignment="Center"/>
                        </DockPanel>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chev" Property="Foreground" Value="#0071E3"/></Trigger>
                        <Trigger Property="IsChecked" Value="True">
                          <Setter TargetName="Chev" Property="RenderTransform"><Setter.Value><RotateTransform Angle="180"/></Setter.Value></Setter>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </ToggleButton.Template>
                </ToggleButton>
                <ContentPresenter x:Name="Body" Visibility="Collapsed" Margin="0,0,30,15"/>
              </DockPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="True"><Setter TargetName="Body" Property="Visibility" Value="Visible"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>'''
