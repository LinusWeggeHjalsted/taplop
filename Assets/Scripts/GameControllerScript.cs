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
        if (missionLogic != null)
        {
            Destroy(missionLogic);
        }
        if (hub != null)
        {
            Destroy(hub);
        }
        mainMenu = Instantiate(mainMenuPrefab);
    }

    public void StartMission(string missionName, int missionLength, string endHub)
    {
        // to-do - start loading screen
        if (mainMenu != null)
        {
            Destroy(mainMenu);
        }
        if (hub != null)
        {
            Destroy(hub);
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
        // to-do - add hub to discovered locations in PlayerData
        if (mainMenu != null)
        {
            Destroy(mainMenu);
        }
        if (missionLogic != null)
        {
            Destroy(missionLogic);
        }
        hub = Instantiate(hubPrefab);
        GameObject hubBuilder = hub.transform.Find("Hub Builder").gameObject;
        HubBuilderScript hubBuilderScript = hubBuilder.GetComponent<HubBuilderScript>();
        hubBuilderScript.hubName = hubName;
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
