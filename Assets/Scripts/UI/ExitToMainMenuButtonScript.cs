using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class ExitToMainMenuButtonScript : MonoBehaviour, IPointerDownHandler
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
        PlayerDataScript.Instance.BuildDataFromPlayer(player);
#if !UNITY_WEBGL || UNITY_EDITOR
        PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
        GameControllerScript.Instance.MainMenu();
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
