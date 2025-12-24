using UnityEngine;
using TMPro;
using System.Collections;

public class GameControllerScript : MonoBehaviour
{
    public static GameControllerScript Instance { get; private set; }
    public GameObject mainMenuPrefab;
    public GameObject mainMenu;
    public GameObject missionPrefab;
    public GameObject missionLogic;
    public GameObject hubPrefab;
    public GameObject hub;
    public GameObject hubSplashScreenPrefab;
    public GameObject missionSplashScreenPrefab;

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
        StartCoroutine(DisplayMissionSplashScreen(missionName));
    }

    IEnumerator DisplayMissionSplashScreen(string missionName)
    {
        GameObject level = null;
        while (level == null)
        {
            level = GameObject.Find("Level(Clone)");
            yield return null;
        }
        Transform canvas = level.transform.Find("Canvas");
        if (canvas != null)
        {
            GameObject missionSplashScreen = Instantiate(missionSplashScreenPrefab, canvas);
            Transform verticalLayout = missionSplashScreen.transform.Find("Vertical Layout");
            TMP_Text splashText = verticalLayout.Find("Mission Splash Text").GetComponent<TMP_Text>();
            splashText.text = missionName;
            Destroy(missionSplashScreen, 1.5f);
        }
    }

    public void EnterHub(string hubName)
    {
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
        // display hub splash screen
        Transform canvas = hub.transform.Find("Canvas");
        if (canvas != null)
        {
            GameObject hubSplashScreen = Instantiate(hubSplashScreenPrefab, canvas);
            Transform verticalLayout = hubSplashScreen.transform.Find("Vertical Layout");
            TMP_Text splashText = verticalLayout.Find("Hub Splash Text").GetComponent<TMP_Text>();
            splashText.text = hubName;
            Destroy(hubSplashScreen, 1.5f);
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
        hubSplashScreenPrefab = Resources.Load<GameObject>("Prefabs/Hub Splash Screen");
        missionSplashScreenPrefab = Resources.Load<GameObject>("Prefabs/Mission Splash Screen");
#if UNITY_EDITOR
        GameObject devToolsPrefab = Resources.Load<GameObject>("Prefabs/Dev Tools");
        Instantiate(devToolsPrefab);
#endif
        MainMenu();
    }
}
