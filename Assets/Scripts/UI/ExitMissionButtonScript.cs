using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class ExitMissionButtonScript : MonoBehaviour, IPointerDownHandler
{
    public Button button;

    public void OnPointerDown(PointerEventData eventData)
    {
        SoundControllerScript.Instance.PlayButtonClickDownSound();
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickUpSound();
        GameObject player = GameReferences.GetPlayer();
        if (player != null)
        {
            PlayerDataScript.Instance.BuildDataFromPlayer(player);
        }
#if !UNITY_WEBGL || UNITY_EDITOR
        PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
        if (string.IsNullOrEmpty(PlayerDataScript.Instance.lastHub))
        {
            GameControllerScript.Instance.MainMenu();
        }
        else
        {
            GameControllerScript.Instance.EnterHub(PlayerDataScript.Instance.lastHub);
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);

        GameObject missionLogic = GameObject.Find("Mission Logic");
        if (missionLogic == null)
        {
            this.gameObject.SetActive(false);
        }
    }
}
