$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Transfer.psm1') -Force -DisableNameChecking

function Assert-ArchiveThrows([scriptblock]$Action,[string]$Like='*'){
    $message=$null
    try{&$Action|Out-Null}catch{$message=$_.Exception.Message}
    $message|Should Not BeNullOrEmpty
    $message|Should BeLike $Like
}
function Get-BytesHash([byte[]]$Bytes){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
function New-SyntheticExport([string]$Path){
    $files=@{'data\app.db'=[byte[]]::new(300000);'secrets\source\app.env'=[Text.Encoding]::UTF8.GetBytes("TOKEN=synthetic`n")}
    for($i=0;$i -lt 300000;$i+=7){$files['data\app.db'][$i]=[byte]($i % 251)}
    $records=@()
    foreach($target in @('data\app.db','secrets\source\app.env')){
        $full=Join-Path $Path $target
        [IO.Directory]::CreateDirectory((Split-Path -Parent $full))|Out-Null
        [IO.File]::WriteAllBytes($full,$files[$target])
        $records+=@{target=$target;kind='file';bytes=$files[$target].Length;sha256=(Get-BytesHash $files[$target])}
    }
    [IO.File]::WriteAllText((Join-Path $Path 'snapshot-fence-extra.json'),'{"excluded":true}')
    Write-DeploymentJson (Join-Path $Path 'transfer.json') @{planHash='synthetic';operationId='synthetic-op';fence=@{synthetic=$true};directories=@();files=$records}
    @{transferSHA256=(Get-FileHash (Join-Path $Path 'transfer.json')).Hash.ToLowerInvariant();files=$files;records=$records}
}
function New-RawArchive([string]$Path,[object[]]$Entries){
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew)
    try{
        $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
        try{
            foreach($item in $Entries){
                $entry=$zip.CreateEntry($item.name)
                if($item.ContainsKey('attributes')){$entry.ExternalAttributes=$item.attributes}
                if($null -ne $item.bytes){$out=$entry.Open();try{$out.Write($item.bytes,0,$item.bytes.Length)}finally{$out.Dispose()}}
            }
        }finally{$zip.Dispose()}
    }finally{$stream.Dispose()}
    (Get-FileHash $Path).Hash.ToLowerInvariant()
}

Describe 'Compressed frozen-state transfer archive' {
    BeforeEach {
        $script:work=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:export=Join-Path $script:work 'export'
        $script:out=Join-Path $script:work 'protected'
        [IO.Directory]::CreateDirectory($script:out)|Out-Null
        $script:synthetic=New-SyntheticExport $script:export
        $script:proofBytes=[IO.File]::ReadAllBytes((Join-Path $script:export 'transfer.json'))
        $script:valid=@(
            @{name='transfer.json';bytes=$script:proofBytes}
            @{name='data/app.db';bytes=$script:synthetic.files['data\app.db']}
            @{name='secrets/source/app.env';bytes=$script:synthetic.files['secrets\source\app.env']}
        )
    }
    It 'round-trips exactly transfer.json and declared files and excludes export extras' {
        $result=New-TransferArchive $script:export $script:synthetic.transferSHA256 $script:out 'state.zip'
        $result.archiveSHA256|Should Be (Get-FileHash (Join-Path $script:out 'state.zip')).Hash.ToLowerInvariant()
        $result.files|Should Be 2
        $zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $script:out 'state.zip'))
        try{(@($zip.Entries|ForEach-Object FullName|Sort-Object) -join ',')|Should Be 'data/app.db,secrets/source/app.env,transfer.json'}finally{$zip.Dispose()}
        $destination=Join-Path $script:work 'extracted'
        $proof=Expand-TransferArchive (Join-Path $script:out 'state.zip') $destination $script:synthetic.transferSHA256 $result.archiveSHA256
        $proof.operationId|Should Be 'synthetic-op'
        (Get-FileHash (Join-Path $destination 'transfer.json')).Hash.ToLowerInvariant()|Should Be $script:synthetic.transferSHA256
        foreach($record in $script:synthetic.records){
            (Get-FileHash (Join-Path $destination $record.target)).Hash.ToLowerInvariant()|Should Be $record.sha256
        }
        Test-Path (Join-Path $destination 'snapshot-fence-extra.json')|Should Be $false
        (Test-TransferArchive (Join-Path $script:out 'state.zip') $script:synthetic.transferSHA256 $result.archiveSHA256 -VerifyContent).operationId|Should Be 'synthetic-op'
    }
    It 'creates only from the approved proof into a new file outside the export' {
        Assert-ArchiveThrows {New-TransferArchive $script:export ('0'*64) $script:out 'state.zip'} '*differs from the approved transferSHA256*'
        Assert-ArchiveThrows {New-TransferArchive $script:export $script:synthetic.transferSHA256 $script:out '..\state.zip'} '*simple .zip*'
        Assert-ArchiveThrows {New-TransferArchive $script:export $script:synthetic.transferSHA256 $script:export 'state.zip'} '*inside the frozen export*'
        [IO.File]::WriteAllText((Join-Path $script:out 'state.zip'),'keep')
        Assert-ArchiveThrows {New-TransferArchive $script:export $script:synthetic.transferSHA256 $script:out 'state.zip'} '*create-only*'
        [IO.File]::ReadAllText((Join-Path $script:out 'state.zip'))|Should Be 'keep'
    }
    It 'removes its own partial archive when an export file no longer matches the proof' {
        $bytes=[IO.File]::ReadAllBytes((Join-Path $script:export 'data\app.db'));$bytes[10]=$bytes[10] -bxor 1
        [IO.File]::WriteAllBytes((Join-Path $script:export 'data\app.db'),$bytes)
        Assert-ArchiveThrows {New-TransferArchive $script:export $script:synthetic.transferSHA256 $script:out 'state.zip'} '*differs from the proof*'
        Test-Path (Join-Path $script:out 'state.zip')|Should Be $false
    }
    It 'rejects archive and transfer hashes that are not the approved bytes' {
        $path=Join-Path $script:work 'a.zip';$hash=New-RawArchive $path $script:valid
        Assert-ArchiveThrows {Test-TransferArchive $path $script:synthetic.transferSHA256 ('a'*64)} '*transferArchiveSHA256*'
        Assert-ArchiveThrows {Test-TransferArchive $path ('b'*64) $hash} '*approved transferSHA256*'
        Assert-ArchiveThrows {Test-TransferArchive $path $script:synthetic.transferSHA256 $hash.ToUpperInvariant()} '*lowercase*'
        (Test-TransferArchive $path $script:synthetic.transferSHA256 $hash).operationId|Should Be 'synthetic-op'
    }
    $attacks=@(
        @{label='extra entry';like='*extra or missing*';change={param($e) $e+@{name='data/extra.bin';bytes=[byte[]]@(1)}}}
        @{label='missing entry';like='*extra or missing*';change={param($e) @($e[0],$e[1])}}
        @{label='case-insensitive duplicate';like='*duplicate*';change={param($e) $e+@{name='DATA/APP.DB';bytes=[byte[]]@(1)}}}
        @{label='traversal';like='*unsafe*';change={param($e) $e+@{name='data/../../evil.txt';bytes=[byte[]]@(1)}}}
        @{label='backslash path';like='*unsafe*';change={param($e) $e+@{name='data\evil.txt';bytes=[byte[]]@(1)}}}
        @{label='absolute path';like='*unsafe*';change={param($e) $e+@{name='/evil.txt';bytes=[byte[]]@(1)}}}
        @{label='drive path';like='*unsafe*';change={param($e) $e+@{name='C:/evil.txt';bytes=[byte[]]@(1)}}}
        @{label='alternate data stream';like='*unsafe*';change={param($e) $e+@{name='data/app.db:evil';bytes=[byte[]]@(1)}}}
        @{label='trailing dot alias';like='*unsafe*';change={param($e) $e+@{name='data/app.db.';bytes=[byte[]]@(1)}}}
        @{label='device name';like='*unsafe*';change={param($e) $e+@{name='data/NUL.txt';bytes=[byte[]]@(1)}}}
        @{label='directory entry';like='*unsafe*';change={param($e) $e+@{name='data/';bytes=$null}}}
        @{label='unix symlink';like='*regular files*';change={param($e) $e[0];@{name='data/app.db';bytes=$e[1].bytes;attributes=[int](0xA1FF -shl 16)};$e[2]}}
        @{label='reparse attribute';like='*regular files*';change={param($e) $e[0];@{name='data/app.db';bytes=$e[1].bytes;attributes=0x400};$e[2]}}
        @{label='length larger than proof';like='*length differs*';change={param($e) $e[0];@{name='data/app.db';bytes=($e[1].bytes+[byte[]]@(0))};$e[2]}}
        @{label='length shorter than proof';like='*length differs*';change={param($e) $e[0];@{name='data/app.db';bytes=$e[1].bytes[0..99]};$e[2]}}
    )
    foreach($attack in $attacks){
        It "rejects $($attack.label) before writing any extraction output" {
            $path=Join-Path $script:work 'attack.zip'
            $hash=New-RawArchive $path @(& $attack.change $script:valid)
            $destination=Join-Path $script:work 'extracted'
            Assert-ArchiveThrows {Expand-TransferArchive $path $destination $script:synthetic.transferSHA256 $hash} $attack.like
            Test-Path $destination|Should Be $false
        }
    }
    It 'rejects same-length content that differs from the proof hash' {
        $bytes=[byte[]]$script:synthetic.files['data\app.db'].Clone();$bytes[5]=$bytes[5] -bxor 1
        $path=Join-Path $script:work 'content.zip'
        $hash=New-RawArchive $path @($script:valid[0],@{name='data/app.db';bytes=$bytes},$script:valid[2])
        Assert-ArchiveThrows {Test-TransferArchive $path $script:synthetic.transferSHA256 $hash -VerifyContent} '*differs from the proof*'
        Assert-ArchiveThrows {Expand-TransferArchive $path (Join-Path $script:work 'x') $script:synthetic.transferSHA256 $hash} '*differs from the proof*'
    }
    It 'rejects unsafe or duplicate proof targets even when the archive matches them' {
        $bad=@{planHash='synthetic';operationId='x';fence=@{};directories=@();files=@(
            @{target='data\a.db';kind='file';bytes=1;sha256=('a'*64)},@{target='DATA\A.DB';kind='file';bytes=1;sha256=('a'*64)})}
        $proof=[Text.Encoding]::UTF8.GetBytes(($bad|ConvertTo-Json -Depth 5))
        $path=Join-Path $script:work 'dup.zip'
        $hash=New-RawArchive $path @(@{name='transfer.json';bytes=$proof},@{name='data/a.db';bytes=[byte[]]@(1)})
        Assert-ArchiveThrows {Test-TransferArchive $path (Get-BytesHash $proof) $hash} '*duplicate*'
        $bad.files=@(@{target='..\evil.txt';kind='file';bytes=1;sha256=('a'*64)})
        $proof=[Text.Encoding]::UTF8.GetBytes(($bad|ConvertTo-Json -Depth 5))
        $path=Join-Path $script:work 'trav.zip'
        $hash=New-RawArchive $path @(@{name='transfer.json';bytes=$proof},@{name='../evil.txt';bytes=[byte[]]@(1)})
        Assert-ArchiveThrows {Test-TransferArchive $path (Get-BytesHash $proof) $hash} '*unsafe*'
    }
    It 'rejects malformed proof records with a clear error' {
        $bad=@{operationId='x';files=@(@{target='data\a.db';kind='file';bytes=1})}
        $proof=[Text.Encoding]::UTF8.GetBytes(($bad|ConvertTo-Json -Depth 5))
        $path=Join-Path $script:work 'malformed.zip'
        $hash=New-RawArchive $path @(@{name='transfer.json';bytes=$proof},@{name='data/a.db';bytes=[byte[]]@(1)})
        Assert-ArchiveThrows {Test-TransferArchive $path (Get-BytesHash $proof) $hash} '*malformed*'
    }
    It 'creates through the source-local script without a proof operationId' {
        $plain=Join-Path $script:work 'plain'
        [IO.Directory]::CreateDirectory((Join-Path $plain 'data'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $plain 'data\a.db'),'synthetic')
        Write-DeploymentJson (Join-Path $plain 'transfer.json') @{files=@(@{target='data\a.db';kind='file';bytes=9;sha256=(Get-FileHash (Join-Path $plain 'data\a.db')).Hash.ToLowerInvariant()})}
        $result=& (Join-Path $root 'scripts\New-TransferArchive.ps1') -ExportDirectory $plain -ApprovedTransferSHA256 (Get-FileHash (Join-Path $plain 'transfer.json')).Hash.ToLowerInvariant() -OutputRoot $script:out -ArchiveName 'plain.zip' -Confirm:$false
        $result.compressionLevel|Should Be Optimal
        $result.archiveSHA256|Should Be (Get-FileHash (Join-Path $script:out 'plain.zip')).Hash.ToLowerInvariant()
    }
    It 'refuses an existing extraction destination and never overwrites it' {
        $path=Join-Path $script:work 'a.zip';$hash=New-RawArchive $path $script:valid
        $destination=Join-Path $script:work 'extracted'
        [IO.Directory]::CreateDirectory($destination)|Out-Null
        Assert-ArchiveThrows {Expand-TransferArchive $path $destination $script:synthetic.transferSHA256 $hash} '*must be new*'
        @(Get-ChildItem $destination).Count|Should Be 0
    }
    It 'stops reading an entry that expands beyond its declared length' {
        InModuleScope Transfer {
            $source=[IO.MemoryStream]::new([byte[]]::new(2048))
            $thrown=$null
            try{Copy-BoundedStream $source $null 1024}catch{$thrown=$_.Exception.Message}
            $thrown|Should BeLike '*expands beyond*'
        }
    }
}