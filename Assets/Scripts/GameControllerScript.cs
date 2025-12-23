using UnityEngine;

public class GameControllerScript : MonoBehaviour
{
    public static GameControllerScript Instance { get; private set; }
    public GameObject mainMenuPrefab;
    public GameObject mainMenu;
    public GameObject missionPrefab;
    public GameObject missionLogic;
    public GameObject hubPrefab;
    public GameObject hub;

    public void MainMenu()
    {
        GameObject level = GameObject.Find("Level(Clone)");
        if (level != null)
        {
            DestroyImmediate(level);
        }
        if (missionLogic != null)
        {
            Destroy(missionLogic);
        }
        if (hub != null)
        {
            DestroyImmediate(hub);
        }
        mainMenu = Instantiate(mainMenuPrefab);
    }

    public void StartMission(string missionName, int missionLength, string endHub)
    {
        Debug.Log($"starting mission {missionName}");
        // to-do - start loading screen
        if (mainMenu != null)
        {
            Destroy(mainMenu);
        }
        if (hub != null)
        {
            DestroyImmediate(hub);
        }
        GameObject level = GameObject.Find("Level(Clone)");
        if (level != null)
        {
            DestroyImmediate(level);
        }
        if (missionLogic != null)
        {
            DestroyImmediate(missionLogic);
        }
        missionLogic = Instantiate(missionPrefab);
        missionLogic.name = "Mission Logic";
        MissionLogicScript missionLogicScript = missionLogic.GetComponent<MissionLogicScript>();
        missionLogicScript.missionName = missionName;
        missionLogicScript.missionLength = missionLength;
        missionLogicScript.endHub = endHub;
    }

    public void EnterHub(string hubName)
    {
        // to-do - start loading screen
        if (mainMenu != null)
        {
            Destroy(mainMenu);
        }
        GameObject level = GameObject.Find("Level(Clone)");
        if (level != null)
        {
            DestroyImmediate(level);
        }
        if (missionLogic != null)
        {
            Destroy(missionLogic);
        }
        hub = Instantiate(hubPrefab);
        GameObject hubBuilder = hub.transform.Find("Hub Builder").gameObject;
        HubBuilderScript hubBuilderScript = hubBuilder.GetComponent<HubBuilderScript>();
        hubBuilderScript.hubName = hubName;
        PlayerDataScript.Instance.lastHub = hubName;
        if (!PlayerDataScript.Instance.discoveredHubs.Contains(hubName))
        {
            PlayerDataScript.Instance.discoveredHubs.Add(hubName);
        }
    }

    void Awake()
    {
        if (Instance == null)
        {
            Instance = this;
            DontDestroyOnLoad(this.gameObject);
        }
        else
        {
            Destroy(this.gameObject);
        }
    }

    void Start()
    {
        mainMenuPrefab = Resources.Load<GameObject>("Prefabs/Main Menu");
        missionPrefab = Resources.Load<GameObject>("Prefabs/Mission Logic");
        hubPrefab = Resources.Load<GameObject>("Prefabs/Hub");
#if UNITY_EDITOR
        GameObject devToolsPrefab = Resources.Load<GameObject>("Prefabs/Dev Tools");
        Instantiate(devToolsPrefab);
#endif
        MainMenu();
    }
}
