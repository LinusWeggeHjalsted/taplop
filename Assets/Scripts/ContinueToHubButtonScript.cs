using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class ContinueToHubButtonScript : MonoBehaviour
{
    public Button button;
    
    public void OnActivate()
    {
        GameObject player = GameObject.Find("Player");
        PlayerDataScript.Instance.BuildDataFromPlayer(player);
#if !UNITY_WEBGL || UNITY_EDITOR
        PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
        GameControllerScript.Instance.EnterHub(MissionLogicScript.Instance.endHub);
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
