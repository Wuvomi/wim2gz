# 全自动自助制作Windows镜像DD包不求人（WIM转GZ工具）  

### 功能介绍
释放固件时「添加引导」、「格式化」  
自动注入kvm驱动（先检查目录virtio-win.iso文件是否存在，不存在则wget下载）  
自动通过dism计算wim文件大小，根据大小来生成vhd  
选择wim文件中的版本  
跳过OOBE  
关闭防火墙、启用RDP、关闭RDP网络及验证、修改端口为3389、关闭开机3键  
还原后自动扩容硬盘  
自动启用Administrator  
自动下载、安装7zip（根据目前使用的版本）  
