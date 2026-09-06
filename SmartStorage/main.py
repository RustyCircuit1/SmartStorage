import shutil
from ftplib import FTP
from pathlib import Path

destinations = [
    'E:/Program Files (x86)/Steam/steamapps/common/Windrose/R5/Binaries/Win64/ue4ss/Mods/SmartStorage/Scripts',
    'E:/Program Files (x86)/Steam/steamapps/common/Windrose/R5/Builds/WindowsServer/R5/Binaries/Win64/ue4ss/Mods/SmartStorage/Scripts'
]

ftps = [
    '/R5/Binaries/Win64/ue4ss/Mods/SmartStorage/Scripts'
]

ftpSettings = {
    'host': '213.136.73.171',
    'port': '28531',
    'username': 'gpftp46789041861194533',
    'password': 'kLHfz6SK'
}

origin = 'D:/Coding/Mods/Windrose/SmartStorage/SmartStorage/Scripts'


for destination in destinations:
    #if not destination.startswith('ftp://'):
    shutil.copytree(origin, destination, dirs_exist_ok=True)
    continue

ftp = FTP()
ftp.connect(ftpSettings['host'], int(ftpSettings['port']))
ftp.login(ftpSettings['username'], ftpSettings['password'])

local_folder = Path(origin)
remote_folder = ftps[0]

def upload_folder(local_path, remote_path):
    try:
        ftp.mkd(remote_path)
    except:
        pass

    for item in local_path.iterdir():
        remote_item = f"{remote_path}/{item.name}"

        if item.is_dir():
            upload_folder(item, remote_item)
        else:
            with open(item, "rb") as f:
                ftp.storbinary(f"STOR {remote_item}", f)

upload_folder(local_folder, remote_folder)

ftp.quit()
