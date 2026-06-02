FROM teddysun/xray:latest

# 复制伪装网页和动态启动脚本到镜像中
COPY index.html /etc/xray/index.html
COPY entrypoint.sh /entrypoint.sh

# 赋予启动脚本可执行权限
RUN chmod +x /entrypoint.sh

# 声明容器内部使用的默认网页端口
EXPOSE 80

# 设置容器启动时的入口脚本
ENTRYPOINT ["/entrypoint.sh"]
