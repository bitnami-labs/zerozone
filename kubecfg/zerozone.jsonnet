local kube = import 'kube.libsonnet';

{
  namespace:: { metadata+: { namespace: 'zerozone' } },
  ns: kube.Namespace($.namespace.metadata.namespace),

  svc: kube.Service('zerozone') + $.namespace {
    target_pod: $.zerozone.spec.template,
    port: 53,
    spec+: {
      type: 'LoadBalancer',

      // kube.Service failes to copy the protocol from the target_pod
      local sport = super.ports[0],
      ports: [
        sport {
          protocol: 'UDP',
        },
      ],
    },
  },

  cfg: kube.ConfigMap('zerozone') + $.namespace {
    data: {
      Corefile: |||
        0zone.mkm.pub:8053 {
            zerozone https://ipfs.io
            file /cfg/root.txt
            prometheus localhost:9253
            errors
            log
            debug
        }
      |||,
      'root.txt': |||
        @   IN SOA 0zone.mkm.pub hostmaster.0zone.mkm.pub. (
            2018111100 ; serial
            3600       ; refresh
            1800       ; retry
            604800     ; expire
            600 )      ; ttl

            NS  0zone.ns.mkm.pub.
      |||,
    },
  },

  zerozone: kube.Deployment('zerozone') + $.namespace {
    spec+: {
      template+: {
        spec+: {
          default_container: 'zerozone_server',
          containers_+: {
            debug: kube.Container('debug') {
              image: 'ubuntu',
              args: ['/bin/sleep', '10000000'],
              volumeMounts_+: {
                cfg: {
                  mountPath: '/cfg',
                },

              },
              resources+: {
                requests+: { memory: '10Mi' },
              },
            },

            zerozone_server: kube.Container('zerozone-server') {
              image: 'mkmik/zerozone-server@sha256:6d61bf8829f5399f16723618470cf6d6a0ccdfa961606203a3628deb4ed8e5ae',
              args: ['-conf', '/cfg/Corefile'],
              ports_+: {
                dns: { containerPort: 8053, protocol: 'UDP' },
              },
              volumeMounts_+: {
                cfg: {
                  mountPath: '/cfg',
                },
              },
              resources+: {
                requests+: { memory: '10Mi' },
              },
            },
          },
          volumes_: +{
            cfg: {
              configMap: { name: 'zerozone' },
            },
          },
          automountServiceAccountToken: false,
          terminationGracePeriodSeconds: 1,
        },
      },
    },
  },

  ipfsSvc: kube.Service('ipfs') + $.namespace {
    target_pod: $.ipfs.spec.template,
    spec+: {
      ports: [
        { name: 'api', port: 5001 },
      ],
    },
  },

  // zerozone dns server will talk to this local ipfs node set in order to fetch zones
  ipfs: kube.Deployment('ipfs') + $.namespace {
    local this = self,
    spec+: {
      template+: {
        spec+: {
          securityContext+: {
            runAsNonRoot: true,  // should run as ipfs
            fsGroup: 100,  // "users"
            runAsUser: 1000,  // "ipfs"
          },
          initContainers_+:: {
            config: kube.Container('config') {
              image: this.spec.template.spec.containers_.go_ipfs.image,
              command: ['sh', '-e', '-x', '-c', self.shcmd],
              shcmd:: |||
                test ! -e /data/ipfs/config || exit 0
                echo "Continuing to initialize"
                ipfs init --bits 4096 --empty-repo --profile server

                ipfs config -- "Addresses.API" "/ip4/0.0.0.0/tcp/5001"
              |||,
              volumeMounts_+: {
                data: { mountPath: '/data/ipfs' },
              },
            },
          },
          containers_+: {
            go_ipfs: kube.Container('go-ipfs') {
              image: 'ipfs/go-ipfs:v0.4.18',
              args: ['daemon', '--enable-namesys-pubsub', '--enable-pubsub-experiment'],
              ports_+: {
                api: { containerPort: 5001 },
              },
              volumeMounts_+: {
                data: { mountPath: '/data/ipfs' },
              },
              resources+: {
                requests+: { memory: '10Mi' },
              },
            },
          },
          volumes_: +{
            data: {
              emptyDir: {},
            },
          },
        },
      },
    },
  },
}
